{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

module Test.Ouroboros.Storage
  ( tests
  ) where

import           Control.Monad.Catch (MonadMask)
import           Control.Monad.Except
import qualified Data.Binary as Binary
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BL
import qualified Data.ByteString.Builder.Extra as BL
import qualified Data.ByteString.Lazy.Char8 as C8
import           Data.Either (isRight)
import           Data.List (nub, sort)
import qualified Data.Map.Strict as M
import           Data.Maybe (isJust)
import           Data.Serialize
import qualified Data.Set as S
import           Data.Word (Word64)
import           System.IO.Temp

import qualified System.Directory as Dir

import           Test.Ouroboros.Storage.Immutable.Sim (demoScript)
import           Test.QuickCheck
import           Test.QuickCheck.Monadic
import           Test.Tasty (TestTree, testGroup)
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck (testProperty)

import           Ouroboros.Network.MonadClass
import           Ouroboros.Storage.FS.Class
import           Ouroboros.Storage.FS.IO (runIOFS)
import           Ouroboros.Storage.FS.Sim
import qualified Ouroboros.Storage.Immutable.DB as Immutable
import qualified Ouroboros.Storage.Volatile.DB as Volatile

--
-- The list of all tests
--

tests :: HasCallStack => TestTree
tests = testGroup "Storage"
  [ testGroup "HasFS"
    [ testCase     "touchFile works" test_touchFile
    , testCase     "createDirectory works" test_createDirectory
    , testCase     "listDirectory works" test_listDirectory
      -- hOpen
    , testCase     "hOpen on an existent folder succeeds"  test_hOpenDoesExist
    , testCase     "hOpen on an non-existent folder fails" test_hOpenDoesNotExist
    , testProperty "hOpen(Sim) == hOpen(IO)"     $ prop_hOpenEquivalence
    , testProperty "hOpen read contention"       $ prop_hOpenReadContention
    , testProperty "hOpen read/write contention" $ prop_hOpenReadWriteContention
    , testProperty "hOpen on directories fails"  $ prop_hOpenDirectory
      -- hClose
    , testCase     "hClose twice no-op "  $ test_hCloseTwice
    , testProperty "hClose twice no-op equivalence"  $ prop_hCloseTwiceEquivalence
      -- hPut
    , testProperty "hPut equivalence"  $ prop_hPutEquivalence
      -- hPutBuffer
    , testProperty "hPutBuffer chunk boundaries"  $ prop_hPutBufferBoundaries
      -- hGet
    , testProperty "hGet equivalence"  $ prop_hGetEquivalence
      -- hTruncate
    , testProperty "hTruncate equivalence"  $ prop_hTruncateEquivalence
      -- doesFileExist
    , testCase "doesFileExist yields True  for an existing file" $ test_doesFileExistOK
    , testCase "doesFileExist yields False for a non-existing file" $ test_doesFileExistKO
      -- doesDirectoryExist
    , testCase "doesDirectoryExist yields True  for an existing directory" $ test_doesDirectoryExistOK
    , testCase "doesDirectoryExist yields False for a non-existing directory" $ test_doesDirectoryExistKO
      -- mockDemo
    , testProperty "mockDemo equivalence"        $ prop_mockDemo
    ]
  , testGroup "Immutable Storage"
    [ testCase "What you store is what you get" test_appendAndGet
    , testProperty "append/get roundtrip" prop_appendAndGetRoundtrip
    , testProperty "Inconsistent slot error equivalence" prop_inconsistentSlotErrorEquivalence
    , testProperty "Epoch is read only error equivalence" prop_epochIsReadOnlyErrorEquivalence
    , testProperty "Read from invalid epoch error equivalence" prop_slotDoesNotExistErrorEquivalence
      -- demoScript
    , testProperty "demoScript equivalence" prop_demoSimEquivalence
    ]
  ,
  testGroup "Volatile Storage"
    [
      testProperty "parser round trips" prop_roundTrips
    , testProperty "volatileDB roundTrips api equivalence" prop_VolatileRoundTripsEquivalence
    , testProperty "volatileDB roundTrips" prop_VolatileRoundTrips
    , testProperty "volatileDB reOpen" prop_VolatileReOpenState
    , testProperty "volatileDB reOpen and Write" prop_VolatileReOpenWrite
    , testProperty "volatileDB garbage collect" prop_VolatileGarbageCollect
    , testProperty "volatileDB garbage collect state" prop_VolatileGarbageState
    , testProperty "volatileDB no slot exception" prop_VolatileNoSlot
    , testProperty "volatileDB duplicated slot" prop_VolatileDuplicatedSlot
    , testProperty "volatileDB undisputable lookup" prop_VolatileUndisputableLookup
    ]
  ]

{------------------------------------------------------------------------------
 Handy combinators
-------------------------------------------------------------------------------}

withMockFS :: MonadSTM m
           => SimFS m (Either e a)
           -> ((Either e a, MockFS) -> m b)
           -> m b
withMockFS sim assertion = do
    r <- runSimFS sim newEmptyMockFS
    assertion r

withMockFSE :: MonadSTM m
            => SimFS m (Either FsError a)
            -> ((Either FsError a, MockFS) -> m b)
            -> m b
withMockFSE = withMockFS

expectError :: (HasCallStack, Show a)
            => (FsError -> Bool)
            -> Either FsError a
            -> String
            -> Assertion
expectError errPred r lbl =
    case r of
         Right x -> fail ("Return value " <> show x <> " was not an error.")
         Left  e -> assertEqual (prettyMsg e) True (errPred e)
    where
        prettyMsg :: FsError -> String
        prettyMsg err =
            lbl <> ": error type was "
                <> prettyFSError err
                <> ", which is not what I was expecting."

-- | Given a \"script\", runs it over a simulated FS and over IO (using a
-- temporary, throw-away folder) and compare the results.
apiEquivalence :: (HasCallStack, Eq a)
               => (forall m. (MonadMask m, MonadSTM m, HasCallStack, HasFSE m) => m (Either b a))
               -> (b -> b -> Bool)
               -> (b -> String)
               -> Assertion
apiEquivalence m cmpError prettyError = do
    sysTmpDir <- Dir.getTemporaryDirectory
    withTempDirectory sysTmpDir "cardano." $ \tmpDir -> do
        (r1, fs') <- runSimFS m newEmptyMockFS
        r2 <- runIOFS m tmpDir
        case (r1, r2) of
            (Left e1, Left e2) ->
                assertBool ("SimFS & IO didn't agree on the API. "
                           <> "The implementation differs.\n\n"
                           <> "Sim returned: " <> prettyError e1  <> "\n\n"
                           <> "IO  returned: " <> prettyError e2  <> "\n\n")
                           (e1 `cmpError` e2)
            (Right x1, Right x2) ->
                assertBool "SimFS & IO didn't yield the same result."
                           (x1 == x2)
            (Left e, Right _) ->
                fail $ "SimFS returned "
                    <> prettyError e
                    <> ", but IO succeeded.\n\n"
                    <> "Sim FS: " <> show fs' <> "\n\n"
            (Right _, Left e) ->
                fail $ "IO returned "
                    <> prettyError e
                    <> ", but SimFS succeeded.\n\n"
                    <> "Sim FS: " <> show fs' <> "\n\n"

{------------------------------------------------------------------------------
 The tests proper
-------------------------------------------------------------------------------}

test_touchFile :: Assertion
test_touchFile = do
    touchFile ["foo.txt"] (FolderOnDisk mempty) @?=
        (FolderOnDisk $ M.fromList [("foo.txt", FileOnDisk mempty)])
    let action = touchFile ["demo", "bar.md"] . touchFile ["demo", "foo.txt"]
    action (FolderOnDisk $ M.fromList [("demo", FolderOnDisk mempty)]) @?=
        (FolderOnDisk $ M.fromList [
            ("demo", FolderOnDisk $ M.fromList [
              ("foo.txt", FileOnDisk mempty)
            , ("bar.md", FileOnDisk mempty)
            ]
            )])

test_createDirectory :: Assertion
test_createDirectory = do
    let action1 = createDirectory ["foo"]
        result1 = FolderOnDisk $ M.fromList [("foo", FolderOnDisk mempty)]
        action2 = createDirectoryIfMissing True ["demo", "foo"]
        result2 = (FolderOnDisk $ M.fromList [
                    ("demo", FolderOnDisk $ M.fromList [("foo", FolderOnDisk mempty)]
                  )])
    withMockFSE (runExceptT action1) $ \(_, fs1) -> getMockFS fs1 @?= result1
    withMockFSE (runExceptT action2) $ \(_, fs2) -> getMockFS fs2 @?= result2

test_listDirectory :: Assertion
test_listDirectory = do
    let script = runExceptT $ do
             createDirectory ["foo"]
             withFile ["foo", "foo.txt"] WriteMode $ \_ -> return ()
             withFile ["foo", "bar.txt"] WriteMode $ \_ -> return ()
             withFile ["foo", "quux.md"] WriteMode $ \_ -> return ()
             listDirectory ["foo"]
    withMockFSE script $ \(r, _) ->
        case r of
             Left e     -> fail (show e)
             Right dirs -> sort dirs @?= sort ["foo.txt", "bar.txt", "quux.md"]

--
-- hOpen tests
--

test_hOpenDoesExist :: Assertion
test_hOpenDoesExist =
    withMockFSE (runExceptT $ hOpen ["foo.txt"] WriteMode) $ \(r, fs) -> do
    assertBool "hOpen failed" (isRight r)
    -- The file must have been created
    assertBool "file not in the mock FS" $
        isJust (index ["foo.txt"] (getMockFS fs))

test_hOpenDoesNotExist :: Assertion
test_hOpenDoesNotExist =
    withMockFS (runExceptT $ hOpen ["test", "foo.txt"] WriteMode) $ \(r, _) ->
    expectError isResourceDoesNotExistError r "return type was not FsResourceDoesNotExist"

prop_hOpenEquivalence :: Property
prop_hOpenEquivalence = monadicIO $ do
    ioMode   <- pick $ elements [ReadMode, AppendMode, ReadWriteMode]
    run $ apiEquivalence (runExceptT $ do
                             h <- hOpen ["foo.txt"] ioMode
                             hClose h
                         ) sameFsError prettyFSError

-- Opening two read handles on the same file should be allowed in both
-- implementations.
prop_hOpenReadContention :: Property
prop_hOpenReadContention = monadicIO $ do
    run $ apiEquivalence (runExceptT $ do
                             h1 <- hOpen ["foo.txt"] ReadMode
                             h2 <- hOpen ["foo.txt"] ReadMode
                             hClose h1
                             hClose h2
                         ) sameFsError prettyFSError

prop_hOpenReadWriteContention :: Property
prop_hOpenReadWriteContention = monadicIO $ do
    run $ apiEquivalence (runExceptT $ do
                             h2 <- hOpen ["foo.txt"] WriteMode
                             h1 <- hOpen ["foo.txt"] ReadMode
                             hClose h1
                             hClose h2
                         ) sameFsError prettyFSError

prop_hOpenDirectory :: Property
prop_hOpenDirectory = monadicIO $ do
    run $ apiEquivalence (runExceptT $ do
                             createDirectoryIfMissing True ["foo"]
                             h1 <- hOpen ["foo"] WriteMode
                             hClose h1
                         ) sameFsError prettyFSError

prop_mockDemo :: Property
prop_mockDemo = monadicIO $ run $
    apiEquivalence (runExceptT $ do
                       -- The mockDemoScript assumes the presence of some
                       -- files and dirs.
                       createDirectoryIfMissing True ["var", "tmp"]
                       withFile ["var", "tmp", "foo.txt"] WriteMode $ \_ ->
                          return ()
                       mockDemoScript
                   ) sameFsError prettyFSError

--
-- hClose tests
--
test_hCloseTwice :: Assertion
test_hCloseTwice =
    withMockFS (runExceptT $ do
                  h1 <- hOpen ["foo.txt"] WriteMode
                  hClose h1
                  hClose h1
               ) $ \(r, _) ->
    case r of
         Left e   -> fail $ prettyFSError e
         Right () -> return ()

prop_hCloseTwiceEquivalence :: Property
prop_hCloseTwiceEquivalence = monadicIO $ do
    run $ apiEquivalence (runExceptT $ do
                             h1 <- hOpen ["test.txt"] WriteMode
                             hClose h1
                             hClose h1
                         ) sameFsError prettyFSError

prop_hPutEquivalence :: Property
prop_hPutEquivalence = monadicIO $ do
    run $ apiEquivalence (runExceptT $
              withFile ["test.txt"] WriteMode $ \h1 ->
                  hPut h1 (BL.lazyByteString $ C8.pack "haskell-is-nice")
        ) sameFsError prettyFSError

-- In this test purposefully create a very small buffer and we test that our
-- 'bytesWritten' count is consistent across chunks boundaries.
prop_hPutBufferBoundaries :: Property
prop_hPutBufferBoundaries = monadicIO $ do
    bufferSize <- pick $ choose (1, 64)
    input      <- pick $ C8.pack <$> listOf1 (elements ['a' .. 'z'])
    threshold  <- pick $ choose (1, 512)
    run $ apiEquivalence (runExceptT $ do
                             b  <- newBuffer bufferSize
                             h1 <- hOpen ["test.txt"] WriteMode
                             bytesWritten  <-
                                 hPutBuffer h1 b (BL.lazyByteStringThreshold threshold input)
                             _ <- hSeek h1 AbsoluteSeek 0
                             r <- hGet h1 (fromIntegral $ C8.length input)
                             hClose h1
                             return ( fromIntegral bytesWritten == (C8.length input)
                                    , bytesWritten
                                    , r
                                    , C8.toStrict input == r
                                    )
                         ) sameFsError prettyFSError

prop_hGetEquivalence :: Property
prop_hGetEquivalence = monadicIO $ do
    run $ apiEquivalence (runExceptT $
              withFile ["test.txt"] WriteMode $ \h1 -> do
                  b  <- hPut h1 (BL.lazyByteString $ C8.pack "haskell-is-nice")
                  _ <- hSeek h1 AbsoluteSeek 0
                  r1 <- hGet h1 4
                  r2 <- hGet h1 3
                  _ <- hSeek h1 RelativeSeek 3
                  r3 <- hGet h1 4
                  return (b, [r1,r2,r3])
        ) sameFsError prettyFSError

prop_hTruncateEquivalence :: Property
prop_hTruncateEquivalence = monadicIO $ do
    run $ apiEquivalence (runExceptT $
             withFile ["test.txt"] WriteMode $ \h1 -> do
                 b  <- hPut h1 (BL.lazyByteString $ C8.pack "haskell-is-nice")
                 _ <- hSeek h1 AbsoluteSeek 0
                 r1 <- hGet h1 15
                 hTruncate h1 7
                 _ <- hSeek h1 AbsoluteSeek 0
                 r2 <- hGet h1 7
                 hClose h1
                 return (b, [r1,r2])
       ) sameFsError prettyFSError

test_doesFileExistOK :: Assertion
test_doesFileExistOK =
    withMockFS (runExceptT $ do
                  h1 <- hOpen ["foo.txt"] WriteMode
                  hClose h1
                  doesFileExist ["foo.txt"]
               ) $ \(r, _) ->
    case r of
         Left e  -> fail $ prettyFSError e
         Right b -> b @? "doesFileExist didn't work as expected"

test_doesFileExistKO :: Assertion
test_doesFileExistKO =
    withMockFS (runExceptT $ doesFileExist ["foo.txt"]) $ \(r, _) ->
    case r of
         Left e  -> fail $ prettyFSError e
         Right b -> not b @? "doesFileExist didn't work as expected"

test_doesDirectoryExistOK :: Assertion
test_doesDirectoryExistOK =
    withMockFS (runExceptT $ do
                  createDirectoryIfMissing True ["test-dir"]
                  doesDirectoryExist ["test-dir"]
               ) $ \(r, _) ->
    case r of
         Left e  -> fail $ prettyFSError e
         Right b -> b @? "doesDirectoryExist didn't work as expected"

test_doesDirectoryExistKO :: Assertion
test_doesDirectoryExistKO =
    withMockFS (runExceptT $ doesDirectoryExist ["test-dir"]) $ \(r, _) ->
    case r of
         Left e  -> fail $ prettyFSError e
         Right b -> not b @? "doesDirectoryExist didn't work as expected"

--
-- Tests for the immutable storage
--

test_appendAndGet :: Assertion
test_appendAndGet =
    withMockFS (Immutable.withDB ["demo"] 0 $ \db -> runExceptT $ do
          ExceptT $ Immutable.appendBinaryBlob db (0, Immutable.RelativeSlot 0) (BL.lazyByteString . C8.pack $ "haskell")
          ExceptT $ Immutable.getBinaryBlob db (0, Immutable.RelativeSlot 0)
    ) $ \(r, _) ->
      case r of
           Left e  -> fail $ Immutable.prettyImmutableDBError e
           Right b -> b @?= "haskell"

prop_appendAndGetRoundtrip :: Property
prop_appendAndGetRoundtrip = monadicIO $ do
    input <- C8.pack <$> pick arbitrary
    run $ apiEquivalence (Immutable.withDB ["demo"] 0 $ \db -> runExceptT $ do
            ExceptT $ Immutable.appendBinaryBlob db (0, Immutable.RelativeSlot 0) (BL.lazyByteString input)
            r <- ExceptT $ Immutable.getBinaryBlob db (0, Immutable.RelativeSlot 0)
            return (r == C8.toStrict input, r)
        ) Immutable.sameDBError Immutable.prettyImmutableDBError

prop_demoSimEquivalence :: HasCallStack => Property
prop_demoSimEquivalence = monadicIO $ do
    run $ apiEquivalence demoScript Immutable.sameDBError Immutable.prettyImmutableDBError

-- Trying to append to a slot \"in the past\" should be an error, both in Sim
-- and IO.
prop_inconsistentSlotErrorEquivalence :: HasCallStack => Property
prop_inconsistentSlotErrorEquivalence = monadicIO $ do
    run $ apiEquivalence (Immutable.withDB ["demo"] 0 $ \db -> runExceptT $ do
                             ExceptT $ Immutable.appendBinaryBlob db (0, Immutable.RelativeSlot 3)
                                                           (BL.lazyByteString . C8.pack $ "test")
                             ExceptT $ Immutable.appendBinaryBlob db (0, Immutable.RelativeSlot 2)
                                                           (BL.lazyByteString . C8.pack $ "haskell")
                             return ()
                         ) Immutable.sameDBError Immutable.prettyImmutableDBError

prop_slotDoesNotExistErrorEquivalence :: HasCallStack => Property
prop_slotDoesNotExistErrorEquivalence = monadicIO $ do
    run $ apiEquivalence (Immutable.withDB ["demo"] 0 $ \db -> runExceptT $ do
                             _   <- ExceptT $ Immutable.getBinaryBlob db (0, Immutable.RelativeSlot 0)
                             return ()
                         ) Immutable.sameDBError Immutable.prettyImmutableDBError

-- Trying to re-open the DB not on the most-recent-epoch should trigger an
-- error, both in Sim and IO.
prop_epochIsReadOnlyErrorEquivalence :: HasCallStack => Property
prop_epochIsReadOnlyErrorEquivalence = monadicIO $ do
    run $ apiEquivalence (runExceptT $ do
                             ExceptT $ Immutable.withDB ["demo"] 0 $ \db -> runExceptT $ do
                               ExceptT $ Immutable.appendBinaryBlob db (0, Immutable.RelativeSlot 0)
                                                             (BL.lazyByteString . C8.pack $ "test")
                               ExceptT $ Immutable.appendBinaryBlob db (1, Immutable.RelativeSlot 0)
                                                             (BL.lazyByteString . C8.pack $ "haskell")
                             -- The second Immutable.withDB should fail.
                             ExceptT $ Immutable.withDB ["demo"] 0 $ \_ -> return $ Right ()
                             return ()
                         ) Immutable.sameDBError Immutable.prettyImmutableDBError

myParser :: (Monad m, HasFSE m) => Volatile.Parser m
myParser = Volatile.Parser {
    Volatile.parse = \hndl path -> do
        let go :: (Monad m, HasFSE m)
               => M.Map Word64 (Int, (Volatile.Epoch, Volatile.RelativeSlot))
               -> Word64
               -> FsHandle (ExceptT FsError m)
               -> Int
               -> [VolSlot]
               -> m (Either Volatile.VolatileDBError (Word64, M.Map Word64 (Int, (Volatile.Epoch, Volatile.RelativeSlot))))
            go mp n hndl' trials slots = do
                mbs <- runExceptT $ Volatile.liftFsError $ hGet hndl' 16
                case mbs of
                    Left e -> return $ Left e
                    Right bs -> do
                        if BS.length bs == 0 then return $ Right (n, mp)
                        else do
                            let Right (sl :: VolSlot) = decode bs
                            if elem sl slots
                            then
                                return $ Left $ Volatile.VParserError $ Volatile.DuplicatedSlot $ M.singleton sl (path, path)
                            else
                                let mp' = M.insert n (16, sl) mp
                                in go mp' (n + 16) hndl' (trials + 1) (sl : slots)
        (n, mp) <- ExceptT $ go M.empty 0 hndl 0 []
        return (n, mp)
    }

type VolSlot = (Volatile.Epoch, Volatile.RelativeSlot)

prop_roundTrips :: HasCallStack => [VolSlot] -> Property
prop_roundTrips ls = property $ (16 * (length ls), ls) === (fromIntegral $ C8.length bs, ls')
    where
        bs = C8.concat $ Binary.encode <$> ls
        ls' = go bs
        go bs' =
            if C8.length bs' == 0 then []
            else
                let (bs1, bsRest) = C8.splitAt 16 bs'
                    sl = Binary.decode bs1
                in sl : go bsRest

prop_VolatileRoundTripsEquivalence :: HasCallStack => [VolSlot] -> Property
prop_VolatileRoundTripsEquivalence ls = monadicIO $ do
    let ls' = (\sl -> (sl, Binary.encode sl)) <$> ls
    run $ apiEquivalence (runExceptT $ do
        ExceptT $ Volatile.withDB ["demo"] myParser 5 $ \db -> runExceptT $ do
            forM_ ls' $ \(slot, enc) -> ExceptT $ Volatile.putBlock db slot (BL.lazyByteString enc)
            forM_ ls $ \slot -> ExceptT $ Volatile.getBlock db slot
        )   Volatile.sameDBError show

prop_VolatileRoundTrips :: HasCallStack => [VolSlot] -> Property
prop_VolatileRoundTrips ls = monadicIO $
    run $ do
        let ls' = (\sl -> (sl, Binary.encode sl)) <$> ls
        let action = runExceptT $ do
                ExceptT $ Volatile.withDB ["demo"] myParser 5 $ \db -> runExceptT $ do
                    forM_ ls' $ \(slot, enc) -> ExceptT $ Volatile.putBlock db slot (BL.lazyByteString enc)
                    forM ls $ \slot -> ExceptT $ Volatile.getBlock db slot
        sysTmpDir <- Dir.getTemporaryDirectory
        withTempDirectory sysTmpDir "cardano" $ \tmpDir -> do
            r1 <- runIOFS action tmpDir
            case r1 of
                Left e -> fail $ "IO failed with " <> show e
                Right bss ->
                    (decode <$> bss) @?= (Right <$> ls)


prop_VolatileReOpenWrite :: HasCallStack => [VolSlot] -> [VolSlot] -> Property
prop_VolatileReOpenWrite ls1 ls2 = monadicIO $
    run $ do
        let ls1' = (\sl -> (sl, Binary.encode sl)) <$> ls1
        let ls2' = (\sl -> (sl, Binary.encode sl)) <$> ls2
        let action = runExceptT $ do
                    db1 <- Volatile.openDB ["reopen"] myParser 5
                    forM_ ls1' $ \(slot, enc) -> ExceptT $ Volatile.putBlock db1 slot (BL.lazyByteString enc)
                    Volatile.closeDB db1
                    db2 <- Volatile.openDB ["reopen"] myParser 5
                    forM_ ls2' $ \(slot, enc) -> ExceptT $ Volatile.putBlock db2 slot (BL.lazyByteString enc)
                    ret <- forM (ls1 <> ls2) $ \slot -> ExceptT $ Volatile.getBlock db2 slot
                    Volatile.closeDB db2
                    return ret
        sysTmpDir <- Dir.getTemporaryDirectory
        withTempDirectory sysTmpDir "cardano" $ \tmpDir -> do
            r <- runIOFS action tmpDir
            case r of
                Left e -> fail $ "IO failed with " <> show e
                Right bss ->
                    (decode <$> bss) @?= (Right <$> (ls1 <> ls2))


prop_VolatileReOpenState :: HasCallStack => [VolSlot] -> Property
prop_VolatileReOpenState ls = monadicIO $
    run $ do
        let ls' = (\sl -> (sl, Binary.encode sl)) <$> ls
        let action = runExceptT $ do
                    db1 <- Volatile.openDB ["reopen2"] myParser 5
                    forM_ ls' $ \(slot, enc) -> ExceptT $ Volatile.putBlock db1 slot (BL.lazyByteString enc)
                    st1 <- ExceptT $ Right <$> Volatile.getInternalState db1
                    let mp1 = Volatile._currentMap st1
                    Volatile.closeDB db1
                    db2 <- Volatile.openDB ["reopen2"] myParser 5
                    st2 <- ExceptT $ Right <$> Volatile.getInternalState db2
                    let mp2 = Volatile._currentMap st2
                    Volatile.closeDB db2
                    return (mp1, mp2)
        sysTmpDir <- Dir.getTemporaryDirectory
        withTempDirectory sysTmpDir "cardano" $ \tmpDir -> do
            r <- runIOFS action tmpDir
            case r of
                Left e -> fail $ "IO failed with " <> show e
                Right (m1, m2) ->
                    m1 @?= m2

prop_VolatileGarbageCollect :: HasCallStack => VolSlot -> [VolSlot] -> [VolSlot] -> Property
prop_VolatileGarbageCollect special ls1 ls2 = monadicIO $
    run $ do
        let blockPerFile = 5
        let specialEnc = Binary.encode special
        let st1 = S.filter (/= special) $ S.fromList ls1
        let ls1' = (\sl -> (sl, Binary.encode sl)) <$> S.toList st1
        let st2 = S.filter (\sl -> sl /= special && not (sl `S.member` st1)) $ S.fromList ls2
        let ls2' = (\sl -> (sl, Binary.encode sl)) <$> S.toList st2
        let ls' = ls1' <> [(special, specialEnc)] <> ls2'
        let hasSlot ei = case ei of
                            Left (Volatile.SlotDoesNotExistError _ _) -> False
                            _ -> True
        let action =
                Volatile.withDB ["garbage-collect"] myParser blockPerFile $ \db -> runExceptT $ do
                    forM_ ls' $ \(slot, enc) -> ExceptT $ Volatile.putBlock db slot (BL.lazyByteString enc)
                    ExceptT $ Volatile.garbageCollect db special
                    let blocks = sequence . filter hasSlot <$> (forM ls' $ \(slot, _) -> Volatile.getBlock db slot)
                    ExceptT blocks
        sysTmpDir <- Dir.getTemporaryDirectory
        withTempDirectory sysTmpDir "cardano" $ \tmpDir -> do
            r <- runIOFS action tmpDir
            case r of
                Left e -> fail $ "IO failed with " <> show e
                Right bss -> do
                    let lss = chunk blockPerFile ls'
                    let maximumM :: [(VolSlot, C8.ByteString)] -> Bool
                        maximumM [] = False
                        maximumM ls = fst (maximum ls) >= special
                    let lss' = filter maximumM lss
                    let ls'' = concat lss'
                    (decode <$> bss) @?= (Right . fst <$> ls'')

-- | split at regular intervals
chunk :: Int -> [a] -> [[a]]
chunk _ [] = []
chunk n xs = y1 : chunk n y2
  where
    (y1, y2) = splitAt n xs

prop_VolatileGarbageState :: HasCallStack => VolSlot -> [VolSlot] -> [VolSlot] -> Property
prop_VolatileGarbageState special ls1 ls2 = withMaxSuccess 20 $ monadicIO $
    run $ do
        let blockPerFile = 5
        let specialEnc = Binary.encode special
        let set1 = S.filter (/= special) $ S.fromList ls1
        let ls1' = (\sl -> (sl, Binary.encode sl)) <$> S.toList set1
        let set2 = S.filter (\sl -> sl /= special && not (sl `S.member` set1)) $ S.fromList ls2
        let ls2' = (\sl -> (sl, Binary.encode sl)) <$> S.toList set2
        let ls' = ls1' <> [(special, specialEnc)] <> ls2'
        let action = runExceptT $ do
                    db1 <- Volatile.openDB ["garbage-state"] myParser blockPerFile
                    forM_ ls' $ \(slot, enc) -> ExceptT $ Volatile.putBlock db1 slot (BL.lazyByteString enc)
                    ExceptT $ Volatile.garbageCollect db1 special
                    st1 <- ExceptT $ Right <$> Volatile.getInternalState db1
                    Volatile.closeDB db1
                    db2 <- Volatile.openDB ["garbage-state"] myParser blockPerFile
                    st2 <- ExceptT $ Right <$> Volatile.getInternalState db2
                    Volatile.liftFsError $ hClose $ Volatile._currentWriteHandle st1
                    Volatile.liftFsError $ hClose $ Volatile._currentWriteHandle st2
                    return (st1, st2)
        sysTmpDir <- Dir.getTemporaryDirectory
        withTempDirectory sysTmpDir "cardano" $ \tmpDir -> do
            r <- runIOFS action tmpDir
            case r of
                Left e -> fail $ "IO failed with " <> show e
                Right (st1, st2) -> st1 @?= st2

prop_VolatileNoSlot :: HasCallStack => [VolSlot] -> VolSlot -> Property
prop_VolatileNoSlot ls special = monadicIO $
    run $ do
        let ls' = (\sl -> (sl, Binary.encode sl)) <$> (filter (/= special) ls)
        let action =
                Volatile.withDB ["no-slot"] myParser 5 $ \db -> runExceptT $ do
                    forM_ ls' $ \(slot, enc) -> ExceptT $ Volatile.putBlock db slot (BL.lazyByteString enc)
                    ExceptT $ Volatile.getBlock db special
        sysTmpDir <- Dir.getTemporaryDirectory
        withTempDirectory sysTmpDir "cardano" $ \tmpDir -> do
            r <- runIOFS action tmpDir
            case r of
                Left (Volatile.SlotDoesNotExistError sp _) -> sp @?= special
                somethingElse -> fail $ "IO failed with " <> show somethingElse <> " instead of SlotDoesNotExistError"

prop_VolatileDuplicatedSlot :: HasCallStack => [VolSlot] -> VolSlot -> Property
prop_VolatileDuplicatedSlot ls special = mod (1 + length (nub ls)) 5 /= 0 ==> monadicIO $
    run $ do
        let specialEnc = Binary.encode special
        let ls' = (\sl -> (sl, Binary.encode sl)) <$> ls
        let action = runExceptT $ do
                db <- Volatile.openDB ["double-slot"] myParser 5
                ExceptT $ Volatile.putBlock db special (BL.lazyByteString specialEnc)
                forM_ ls' $ \(slot, enc) -> ExceptT $ Volatile.putBlock db slot (BL.lazyByteString enc)
                -- here we intentionally corrupt the fs, so that we can get the wanted error.
                st <- ExceptT $ Right <$> (Volatile.getInternalState db)
                let hndl = Volatile._currentWriteHandle st
                _ <- Volatile.liftFsError $ hPut hndl (BL.lazyByteString specialEnc)
                Volatile.closeDB db
                _ <- Volatile.openDB ["double-slot"] myParser 5
                return ()
        sysTmpDir <- Dir.getTemporaryDirectory
        withTempDirectory sysTmpDir "cardano" $ \tmpDir -> do
            r <- runIOFS action tmpDir
            case r of
                Left (Volatile.VParserError (Volatile.DuplicatedSlot _)) -> return ()
                somethingElse -> fail $ "IO failed with " <> show somethingElse <> " instead of DuplicatedSlot"

prop_VolatileUndisputableLookup :: HasCallStack => [VolSlot] -> Property
prop_VolatileUndisputableLookup ls = mod (length (nub ls)) 5 /= 0 ==> monadicIO $
    run $ do
        let nubLs = nub ls
        let tl = last nubLs
        let ls' = (\sl -> (sl, Binary.encode sl)) <$> nubLs
        let action = runExceptT $ do
                db <- Volatile.openDB ["undisputable-lookup"] myParser 5
                forM_ ls' $ \(slot, enc) -> ExceptT $ Volatile.putBlock db slot (BL.lazyByteString enc)
                -- here we intentionally corrupt the state, so that we can get the wanted error.
                Volatile.modifyTMVar (Volatile._dbInternalState db) $ \st ->
                    return $ (st {
                                      Volatile._currentMap = M.delete (Volatile._currentWritePath st) (Volatile._currentMap st)
                                    , Volatile._currentRevMap = M.delete tl (Volatile._currentRevMap st)
                                    }, ())
                ExceptT $ Volatile.putBlock db tl (BL.lazyByteString $ Binary.encode tl)
        sysTmpDir <- Dir.getTemporaryDirectory
        withTempDirectory sysTmpDir "cardano" $ \tmpDir -> do
            r <- runIOFS action tmpDir
            case r of
                Left (Volatile.UndisputableLookupError _path _mp) -> return ()
                somethingElse -> fail $ "IO failed with " <> show somethingElse <> " instead of UndisputableLookupError"
