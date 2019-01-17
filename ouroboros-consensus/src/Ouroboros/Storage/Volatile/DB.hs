{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}

module Ouroboros.Storage.Volatile.DB where

import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.Except
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as BS
import qualified Data.Text as T
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe
import           Data.Word (Word64)
import           Text.Read (readMaybe)

import           GHC.Stack

import           Ouroboros.Storage.FS.Class

import           Ouroboros.Network.MonadClass


-- This is just a placeholder as we don't have (yet) a proper 'Epoch' type in
-- this codebase.
type Epoch = Word64

-- | A /relative/ 'Slot' within an Epoch.
type RelativeSlot = Word64

type Fd = Int

-- | An opaque handle to an immutable database of binary blobs.
data VolatileDB m = VolatileDB {
      _dbInternalState :: !(TMVar m (InternalState m))
    , _dbFolder        :: !FsPath
    , _maxSlotsPerFile :: !Int
    , _parser          :: !(Parser m)
    }

data InternalState m = InternalState {
      _currentWriteHandle         :: !(FsHandleE m) -- The unique open file we append blocks.
    , _currentWritePath           :: !String -- The path of the file above.
    , _currentWriteOffset         :: !Word64 -- The 'WriteHandle' for the same file.
    , _currentNextFd              :: !Int -- The next file name Id.
    , _currentSlot                :: !(Maybe (Epoch, RelativeSlot)) -- the newest block in the db.
    , _currentMap                 :: !Index -- The content of each file.
    , _currentRevMap              :: !ReverseIndex -- Where to find each block from slot.
    }

instance Eq (InternalState m) where
    x == y =
               _currentWritePath x == _currentWritePath y
            && _currentWriteOffset x == _currentWriteOffset y
            && _currentSlot x == _currentSlot y
            && _currentMap x == _currentMap y
            && _currentRevMap x == _currentRevMap y

instance Show (InternalState m) where
    show InternalState{..} = show (_currentWritePath, _currentWriteOffset, _currentNextFd, _currentSlot, _currentMap, _currentRevMap)

type Index = Map String (Map Word64 (Int, (Epoch, RelativeSlot)))
type ReverseIndex = Map (Epoch, RelativeSlot) (String, Word64, Int)

-- | Errors which might arise when working with this database.
data VolatileDBError =
    FileSystemError FsError
  | VParserError ParserError
  | SlotDoesNotExistError (Epoch, RelativeSlot) CallStack
  | UndisputableLookupError String Index
  deriving (Show)

sameDBError :: VolatileDBError -> VolatileDBError -> Bool
sameDBError e1 e2 = case (e1, e2) of
    (FileSystemError fs1, FileSystemError fs2) -> sameFsError fs1 fs2
    (VParserError p1, VParserError p2) -> p1 == p2
    (SlotDoesNotExistError sl1 _, SlotDoesNotExistError sl2 _) ->
        sl1 == sl2
    (UndisputableLookupError file1 mp1, UndisputableLookupError file2 mp2) ->
        (file1,mp1) == (file2, mp2)
    _ -> False

data ParserError =
      DuplicatedSlot (Map (Epoch, RelativeSlot) (String, String))
    | SlotsPerFileError Int String String
    deriving (Show, Eq)

newtype Parser m = Parser {
    parse       :: FsHandle (ExceptT FsError m)
                -> String
                -> ExceptT VolatileDBError m (Word64, Map Word64 (Int, (Epoch, RelativeSlot)))
    }

liftFsError :: Functor m => ExceptT FsError m a -> ExceptT VolatileDBError m a
liftFsError = withExceptT FileSystemError

liftParseError :: Functor m => ExceptT ParserError m a -> ExceptT VolatileDBError m a
liftParseError = withExceptT VParserError

withDB :: (HasCallStack, MonadSTM m, MonadMask m, HasFSE m)
       => FsPath
       -> Parser m
       -> Int
       -> (VolatileDB m -> m (Either VolatileDBError a))
       -> m (Either VolatileDBError a)
withDB fsPath parser n action = runExceptT $
    bracket (openDB fsPath parser n) closeDB (ExceptT . action)


-- After opening the db once, the same @maxSlotsPerFile@ must be provided all
-- next opens.
openDB :: (HasCallStack, MonadMask m, MonadCatch m, MonadSTM m, HasFSE m)
       => FsPath
       -> Parser m
       -> Int
       -> ExceptT VolatileDBError m (VolatileDB m)
openDB path parser maxSlotsPerFile = do
    allFiles <- liftFsError $ do
        createDirectoryIfMissing True path
        listDirectory path
    st <- mkInternalState path parser maxSlotsPerFile allFiles
    stVar <- atomically $ newTMVar st
    return $ VolatileDB stVar path maxSlotsPerFile parser

closeDB :: (MonadSTM m, MonadMask m, HasFSE m)
        => VolatileDB m
        -> ExceptT VolatileDBError m ()
closeDB VolatileDB{..} = do
        InternalState{..} <- atomically (takeTMVar _dbInternalState)
        liftFsError $ do
            hClose _currentWriteHandle

getBlock :: forall m. (HasFSE m, MonadSTM m)
         => VolatileDB m
         -> (Epoch, RelativeSlot)
         -> m (Either VolatileDBError ByteString)
getBlock VolatileDB{..} slot = do
    InternalState{..} <- atomically (readTMVar _dbInternalState)
    case Map.lookup slot _currentRevMap of
        Nothing -> return $ Left $ SlotDoesNotExistError slot callStack
        Just (file, w, n) ->  do
            runExceptT $ liftFsError $
                withFile (_dbFolder ++ [file]) ReadMode $ \hndl -> do
                    _ <- hSeek hndl AbsoluteSeek w
                    hGet hndl n

getInternalState :: forall m. (HasFSE m, MonadSTM m)
                 => VolatileDB m
                 -> m (InternalState m)
getInternalState VolatileDB{..} =
    atomically (readTMVar _dbInternalState)

modifyTMVar :: (MonadSTM m, MonadMask m)
            => TMVar m a
            -> (a -> m (a,b))
            -> m b
modifyTMVar m action =
    snd . fst <$> generalBracket (atomically $ takeTMVar m)
       (\oldState ec -> atomically $ case ec of
            ExitCaseSuccess (newState,_) -> putTMVar m newState
            ExitCaseException _ex        -> putTMVar m oldState
            ExitCaseAbort                -> putTMVar m oldState
       ) action

putBlock :: forall m. (MonadMask m, HasFSE m, MonadSTM m)
         => VolatileDB m
         -> (Epoch, RelativeSlot)
         -> BS.Builder
         -> m (Either VolatileDBError ())
putBlock db@VolatileDB{..} slot builder = runExceptT $ do
    modifyTMVar _dbInternalState $ \st@InternalState{..} -> do
        case Map.lookup slot _currentRevMap of
            Just _ -> return (st, ()) -- trying to put an existing block is a no-op.
            Nothing -> do
                case Map.lookup _currentWritePath _currentMap of
                    Nothing -> throwError $ UndisputableLookupError _currentWritePath _currentMap
                    Just fileMp -> do
                        bytesWritten <- liftFsError $ hPut _currentWriteHandle builder
                        let fileMp' = Map.insert _currentWriteOffset (fromIntegral bytesWritten, slot) fileMp
                            mp = Map.insert _currentWritePath fileMp' _currentMap
                            revMp = Map.insert slot (_currentWritePath, _currentWriteOffset, fromIntegral bytesWritten) _currentRevMap
                            size = Map.size fileMp'
                            slot' = updateSlot _currentSlot [slot]
                            st' = st {
                                  _currentWriteOffset = _currentWriteOffset + fromIntegral bytesWritten
                                , _currentSlot = slot'
                                , _currentMap = mp
                                , _currentRevMap = revMp
                            }
                        if size < _maxSlotsPerFile
                        then return (st', ())
                        else (\s -> (s,())) <$> nextFile db st'

nextFile :: forall m. (MonadMask m, HasFSE m, MonadSTM m)
         => VolatileDB m
         -> InternalState m
         -> ExceptT VolatileDBError m (InternalState m)
nextFile VolatileDB{..} st@InternalState{..} = do
    let path = filePath _currentNextFd
    liftFsError $ hClose _currentWriteHandle
    hndl <- liftFsError $ hOpen (_dbFolder ++ [path]) AppendMode
    return $ st {_currentWriteHandle = hndl, _currentWritePath = path, _currentWriteOffset = 0
        , _currentNextFd = _currentNextFd + 1, _currentMap = Map.insert path Map.empty _currentMap}

reOpenFile :: forall m. (MonadMask m, HasFSE m, MonadSTM m)
           => VolatileDB m
           -> InternalState m
           -> ExceptT VolatileDBError m (InternalState m)
reOpenFile VolatileDB{..} st@InternalState{..} = do
   liftFsError $ hClose _currentWriteHandle
   liftFsError $ removeFile $ _dbFolder ++ [_currentWritePath]
   hndl <- liftFsError $ hOpen (_dbFolder ++ [_currentWritePath]) AppendMode
   return $ st {_currentMap = Map.insert _currentWritePath Map.empty _currentMap, _currentWriteHandle = hndl, _currentWriteOffset = 0}


garbageCollect :: forall m. (MonadMask m, HasFSE m, MonadSTM m)
               => VolatileDB m
               -> (Epoch, RelativeSlot)
               -> m (Either VolatileDBError ())
garbageCollect db@VolatileDB{..} slot = runExceptT $ do
    modifyTMVar _dbInternalState $ \st -> do
        let ff st'@InternalState{..} (file, fileMp) =
                let isLess = not $ cmpMaybe (latest fileMp) slot
                    isCurrent = file == _currentWritePath
                    isCurrentNew = _currentWriteOffset == 0
                in
                    if not isLess then return st'
                    else if not isCurrent && isLess
                    then do
                        let slots = snd <$> Map.elems fileMp
                            rv' = foldl (flip Map.delete) _currentRevMap slots
                        liftFsError $ removeFile $ _dbFolder ++ [file]
                        return st{_currentMap = Map.delete file _currentMap, _currentRevMap = rv'}
                    else if isCurrentNew then return st'
                    else do
                        st'' <- reOpenFile db st'
                        let slots = snd <$> Map.elems fileMp
                            rv' = foldl (flip Map.delete) _currentRevMap slots
                        return st''{_currentRevMap = rv'}
        st' <- foldM ff st (Map.toList (_currentMap st))
        let currentSlot' = if Map.size (_currentMap st') == 0 then Nothing else (_currentSlot st')
        let st'' = st'{_currentSlot = currentSlot'}
        return (st'', ())

latest :: Map Word64 (Int, (Epoch, RelativeSlot)) -> Maybe (Epoch, RelativeSlot)
latest mp = maxSlot $ snd <$> Map.elems mp

cmpMaybe :: Ord a => Maybe a -> a -> Bool
cmpMaybe Nothing _ = False
cmpMaybe (Just a) a' = a >= a'

mkInternalState :: forall m. (MonadMask m, HasCallStack, MonadCatch m, HasFSE m)
                => FsPath
                -> Parser m
                -> Int
                -> [String]
                -> ExceptT VolatileDBError m (InternalState m)
mkInternalState basePath parser n files = go Map.empty Map.empty Nothing Nothing files
    where
        lastFd = findNextFd files
        go :: Index
           -> ReverseIndex
           -> Maybe (Epoch, RelativeSlot)
           -> Maybe (String, Word64) -- The relative path and size of the file with less than n blocks, if any found already.
           -> [String]
           -> ExceptT VolatileDBError m (InternalState m)
        go mp revMp slot hasLessThanN leftFiles = case leftFiles of
            [] -> do
                let (fileToWrite, nextFd, mp', offset') = case (hasLessThanN, lastFd) of
                        (Nothing, Nothing) -> (filePath 0, 1, Map.insert (filePath 0) Map.empty mp, 0)
                        (Just _, Nothing) -> error $ "a file was found with less than " ++ show n ++ " blocks, but there are no files parsed."
                        (Nothing, Just lst) -> let fd' = lst + 1 in
                            (filePath fd', lst + 2, Map.insert (filePath fd') Map.empty mp, 0)
                        (Just (wrfile, size), Just lst) -> (wrfile, lst + 1, mp, size)
                hndl <- liftFsError $ hOpen (basePath ++ [fileToWrite]) AppendMode
                return $ InternalState {
                      _currentWriteHandle = hndl
                    , _currentWritePath = fileToWrite
                    , _currentWriteOffset = offset'
                    , _currentNextFd = nextFd
                    , _currentSlot = slot
                    , _currentMap = mp'
                    , _currentRevMap = revMp
                }
            file : restFiles -> do
                let path = basePath ++ [file]
                -- TODO(kde): it's better to make sure the handle is closed even if parse fails.
                -- (offset, fileMp) <- withFile path ReadMode $ \hndl -> undefined
                    -- parse parser hndl file
                (offset, fileMp) <- bracket (liftFsError $ hOpen path ReadMode) (liftFsError . hClose) (\hndl -> parse parser hndl file)
                -- hndl <- liftFsError $ hOpen path ReadMode
                -- (offset, fileMp) <- parse parser hndl file
                -- liftFsError $ hClose hndl
                newRevMp <- ExceptT $ return $ reverseMap file revMp fileMp
                let newMp = Map.insert file fileMp mp
                let newSlot = updateSlot slot (snd <$> (concatMap Map.elems $ Map.elems newMp))
                let newNumber = Map.size fileMp
                newHasLessThanN <- liftParseError $ ExceptT $ return $
                    if newNumber == n then Right hasLessThanN
                    else if newNumber > n || (newNumber < n && (isJust hasLessThanN))
                        then Left (SlotsPerFileError n file (fst $ fromJust hasLessThanN))
                    else Right $ Just (file, offset)
                go newMp newRevMp newSlot newHasLessThanN restFiles

reverseMap :: String -> ReverseIndex -> Map Word64 (Int, (Epoch, RelativeSlot)) -> Either VolatileDBError ReverseIndex
reverseMap file revMp mp = foldM f revMp (Map.toList mp)
    where
        f :: ReverseIndex -- Map (Epoch, RelativeSlot) (String, a)
          -> (Word64, (Int, (Epoch, RelativeSlot)))
          -> Either VolatileDBError (Map (Epoch, RelativeSlot) (String, Word64, Int))
        f rv (w, (n, slot)) = case Map.lookup slot revMp of
            Nothing -> Right $ Map.insert slot (file, w, n) rv
            Just (file', _w', _n') -> Left $ VParserError $ DuplicatedSlot $ Map.fromList [(slot, (file, file'))]

maxSlot :: [(Epoch, RelativeSlot)] -> Maybe (Epoch, RelativeSlot)
maxSlot = updateSlot Nothing

updateSlot :: Maybe (Epoch, RelativeSlot) -> [(Epoch, RelativeSlot)] -> Maybe (Epoch, RelativeSlot)
updateSlot = foldl cmpr
    where
        cmpr :: Maybe (Epoch, RelativeSlot) -> (Epoch, RelativeSlot) -> Maybe (Epoch, RelativeSlot)
        cmpr Nothing sl' = Just sl'
        cmpr (Just sl) sl' = Just $ max sl sl'

filePath :: Fd -> String
filePath fd = "blocks-" ++ show fd ++ ".dat"

-- This will fail if one of the given files does not parse.
findNextFd :: [String] -> Maybe Fd
findNextFd files = foldl go Nothing files
    where
        max' :: Ord a => Maybe a -> a -> a
        max' ma a = case ma of
            Nothing -> a
            Just a' -> max a' a
        go :: Maybe Fd -> String -> Maybe Fd
        go mn file = Just $ max' mn $ fromMaybe (error $ "could not parse" ++ file) (parseFd file)


parseFd :: String -> Maybe Fd
parseFd = readMaybe
            . T.unpack
            . snd
            . T.breakOnEnd "-"
            . fst
            . T.breakOn "."
            . T.pack
