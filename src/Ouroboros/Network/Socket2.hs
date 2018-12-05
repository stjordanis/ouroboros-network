{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Ouroboros.Network.Socket2 where

import           Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Concurrent.QSem
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.ST (RealWorld, stToIO)

import           Ouroboros.Network.ByteChannel
import           Ouroboros.Network.Chain (Chain, ChainUpdate)
import qualified Ouroboros.Network.Chain as Chain
import qualified Ouroboros.Network.ChainProducerState as CPS
import           Ouroboros.Network.ConsumersAndProducers
import           Ouroboros.Network.Protocol
import           Ouroboros.Network.ProtocolInterfaces
import           Ouroboros.Network.Serialise

import           Ouroboros.Network.Pipe2

import qualified Codec.CBOR.Read as CBOR
import qualified Codec.CBOR.Write as CBOR
import           Data.Bits
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import           Data.ByteString.Char8 (pack)
import qualified Data.Map.Strict as M
import           Data.Word
import           Text.Printf

import           Network.Socket hiding (recv, recvFrom, send, sendTo)
import           Network.Socket.ByteString
import           System.Clock

data MultiplexCtx = MultiplexCtx {
      convs :: M.Map Conversation ConversationCtx
    , sem    :: QSem
}

data ConversationCtx = ConversationCtx {
      ccOutQ :: TBQueue BS.ByteString
    , ccInQ  :: TBQueue BS.ByteString
}


multiplexCtxAsByteChannel :: MultiplexCtx -> Conversation -> ByteChannel BS.ByteString IO
multiplexCtxAsByteChannel mx conv =
    case M.lookup conv (convs mx) of
         Nothing  -> error $ "Missing conversation " ++ (show conv) -- XXX
         Just ctx -> channel ctx
  where
    channel ctx = ByteChannel (read ctx) (write ctx)

    read ctx = do
        chunk <- atomically $ readTBQueue (ccInQ ctx)
        if BS.null chunk
           then return ChannelClosed
           else return (ReadChunk chunk $ channel ctx)

    write ctx [] = return $ channel ctx
    write ctx (chunk:chunks) = do
        atomically $ writeTBQueue (ccOutQ ctx) chunk
        signalQSem $ sem mx
        write ctx chunks

data Role
    = Initiator
    | Responder
    deriving (Eq, Ord, Show)

data Conversation
    = ChainHeaderSync Role
    | Ping Role
    deriving (Eq, Ord, Show)

encodeProtocolHeader :: Conversation -> Int -> DeltaQueueTimestamp -> BL.ByteString
encodeProtocolHeader conv len ts = Put.runPut enc
  where
    enc = do
        putConversation conv
        Put.putWord16be (fromIntegral len)
        Put.putWord32be (dqtSec ts)
        Put.putWord32be (dqtFrac ts)

    putConversation (ChainHeaderSync Responder) = Put.putWord16be 1
    putConversation (ChainHeaderSync Initiator) = Put.putWord16be 2
    putConversation (Ping            Initiator) = Put.putWord16be 3
    putConversation (Ping            Responder) = Put.putWord16be 4

decodeProtocolHeader :: BL.ByteString -> Maybe (Conversation, Word16, DeltaQueueTimestamp)
decodeProtocolHeader buf =
    case Get.runGetOrFail dec buf of
         Left  (_, _, _)  -> Nothing
         Right (_, _, ph) -> Just ph

  where
    dec = do
        convid <- Get.getWord16be
        len <- Get.getWord16be
        sec <- Get.getWord32be
        frac <- Get.getWord32be
        return (decodeConveration convid, len, DeltaQueueTimestamp sec frac)

    decodeConveration 1 = ChainHeaderSync Responder
    decodeConveration 2 = ChainHeaderSync Initiator
    decodeConveration 3 = Ping Initiator
    decodeConveration 4 = Ping Responder
    decodeConveration a = error $ "unknow conversation " ++ show a -- XXX

-- | A demonstration that we can run the simple chain consumer protocol
-- over a local socket with full message serialisation, framing etc.
--
demo2 :: (Chain.HasHeader block, Serialise block, Eq block)
      => Chain block -> [ChainUpdate block] -> IO Bool
demo2 chain0 updates = do

    addr:_ <- getAddrInfo Nothing (Just "127.0.0.1") (Just "6060")
    consSock <- socket (addrFamily addr) Stream defaultProtocol
    setSocketOption consSock ReuseAddr 1
    bind consSock (addrAddress addr)
    listen consSock 2

    prodSock <- socket (addrFamily addr) Stream defaultProtocol
    connect prodSock (addrAddress addr)
    (consSock', _) <- accept consSock

    -- Initialise the producer and consumer state to be the same
    producerVar <- newTVarIO (CPS.initChainProducerState chain0)
    consumerVar <- newTVarIO chain0

    producerCtxs <- initMultiplexCtx "producer" prodSock
    let producerChannel = multiplexCtxAsByteChannel producerCtxs (ChainHeaderSync Responder)
    consumerCtxs <- initMultiplexCtx "consumer" consSock'
    let consumerChannel = multiplexCtxAsByteChannel consumerCtxs (ChainHeaderSync Initiator)

    pid <- async $ producer producerVar producerChannel

    -- Apply updates to the producer's chain and let them sync
    _ <- forkIO $ sequence_
           [ do threadDelay 10000000 -- just to provide interest
                atomically $ do
                  p <- readTVar producerVar
                  let Just p' = CPS.applyChainUpdate update p
                  writeTVar producerVar p'
           | update <- updates ]


    r <- runExampleConsumer consumerVar consumerChannel
    case r of
         Left e -> printFailure "consumer" e
         Right a -> printf "consumer done\n" :: IO ()
    printf "Consumer done\n"

    return  True

  where
    recvMsgDoneProducer :: IO ()
    recvMsgDoneProducer = printf "recvMsgDoneProducer"

    producer producerVar producerChannel = do
        r <- runExampleProducer recvMsgDoneProducer producerVar producerChannel
        case r of
             Left e  -> printFailure "producer" e
             Right a -> printf "producer done\n" :: IO ()
        return ()

    printFailure :: String -> ProtocolError CBOR.DeserialiseFailure -> IO ()
    printFailure n (ProtocolDecodeFailure e) = printf "%s: ProtocolDecodeFailure %s\n" n (show e)
    printFailure n ProtocolDisconnected      = printf "%s: ProtocolDisconnected\n" n
    printFailure n ProtocolStateError   = printf "%s: ProtocolStateError\n" n

initMultiplexCtx :: String -> Socket -> IO MultiplexCtx
initMultiplexCtx name sd = do
    sem <- newQSem 0
    mxs <- mapM initConversation [ ChainHeaderSync Initiator, ChainHeaderSync Responder, Ping Initiator
                                 , Ping Responder]
    startupReader name sd $ M.fromList $ map (\(c, mx) -> (reverseDir c, ccInQ mx)) mxs
    startupWriter name sd sem $ map (\(c, mx) -> (c, ccOutQ mx)) mxs

    -- XXX what about our async ids?
    return $ MultiplexCtx (M.fromList mxs) sem

  where
    reverseDir :: Conversation -> Conversation
    reverseDir (ChainHeaderSync Initiator) = ChainHeaderSync Responder
    reverseDir (ChainHeaderSync Responder) = ChainHeaderSync Initiator
    reverseDir (Ping Initiator) = Ping Responder
    reverseDir (Ping Responder) = Ping Initiator

    initConversation :: Conversation -> IO (Conversation, ConversationCtx)
    initConversation conv = do
        rq <- atomically $ newTBQueue 64 -- XXX Should depend on protocol definition
        wq <- atomically $ newTBQueue 64
        return $ (conv, ConversationCtx wq rq)

startupReader :: String
              -> Socket
              -> M.Map Conversation (TBQueue BS.ByteString)
              -> IO (Async ())
startupReader name sd m = async $ socketReader name m sd

startupWriter :: String
              -> Socket
              -> QSem
              -> [(Conversation, TBQueue BS.ByteString)]
              -> IO (Async ())
startupWriter name sd sem queues = async (socketWriter name sem queues sd)


socketWriter :: String
             -> QSem
             -> [(Conversation, TBQueue BS.ByteString)]
             -> Socket
             -> IO ()
socketWriter name sem qs sd = do
    let queues = map (\(conv, q) -> (conv, BS.empty, q)) qs
    loop queues
  where
    loop :: [(Conversation, BS.ByteString, TBQueue BS.ByteString)] -> IO ()
    loop queues = do
        queues' <- mapM checkQueue queues
        loop queues'

    {-
     - Service all queues in a round-robin manner, if a message exceeds
     - 16k it will be split up into several messages and messages from
     - other conversations may be sent in between those messages.
     - Messages belonging to the same conversation will always be delivered
     - in order.
     -}
    checkQueue :: (Conversation, BS.ByteString, TBQueue BS.ByteString) ->
                  IO (Conversation, BS.ByteString, TBQueue BS.ByteString)
    checkQueue (conv, e, q) | BS.empty == e = do
        printf "%s writer: waiting on data\n" name
        waitQSem sem
        blob_m <- atomically $ tryReadTBQueue q
        --printf "writer: awoken\n"
        case blob_m of
             Nothing   -> do
                 signalQSem sem
                 return (conv, BS.empty, q)
             Just blob -> do
                 --printf "ready to send blob with %d bytes of data" $ BS.length blob
                 sendBlob (conv, blob, q)
    checkQueue (conv, b, q) = do
        --printf "continuing to send %d worth of data\n" $ BS.length b
        sendBlob (conv, b, q)

    sendBlob (conv, blob, q) = do
        let (b0, b1) = BS.splitAt 16384 blob
        ts <- getTimestamp
        let header = encodeProtocolHeader conv (BS.length b0) ts
        printf "%s writing header and blob %s %d\n" name (show conv) (BS.length b0)
        sendAll sd $ BL.toStrict $ BL.append header $ BL.fromStrict b0
        return (conv, b1, q)

socketReader :: String
             -> M.Map Conversation (TBQueue BS.ByteString)
             -> Socket
             -> IO ()
socketReader name wqueueMap sd =
    forever $ do
        printf "%s reader: waiting on data\n" name
        header <- recvLen' 12 []
        --printf "reader: read header\n"
        case decodeProtocolHeader (BL.fromStrict header) of
             Nothing -> error "failed to decode header"
             Just (convId, len, ts) ->
                 case M.lookup convId wqueueMap of
                      Nothing     -> error $ "unknown conversation " ++ show convId -- XXX
                      Just wqueue -> do
                          blob <- recvLen' (fromIntegral len) []
                          delay <- timestampOffset ts
                          printf "%s conversation %s delay: %d\n" name (show convId) delay
                          isFull <- atomically $ isFullTBQueue wqueue
                          if isFull
                             then error "wqueue is full"
                             else atomically $ writeTBQueue wqueue blob
  where
    recvLen' :: Int -> [BS.ByteString] -> IO BS.ByteString
    recvLen' 0 bufs = return $ BS.concat $ reverse bufs
    recvLen' l bufs = do
      buf <- recv sd l
      if BS.null buf
          then error "socket closed" -- XXX throw exception
          else recvLen' (l - fromIntegral (BS.length buf)) (buf : bufs)

--
-- XXX Belongs somewhere else


data DeltaQueueTimestamp = DeltaQueueTimestamp {
    dqtSec  :: !Word32
  , dqtFrac :: !Word32
  } deriving Show

ntpOffset :: Num a => a
ntpOffset = 2208988800

nanoS :: Num a => a
nanoS = 10^9

getTimestamp :: IO DeltaQueueTimestamp
getTimestamp = do
  ts <- getTime Realtime
  return $ timeSpecToDeltaQueueTimestamp ts

timeSpecToDeltaQueueTimestamp :: TimeSpec -> DeltaQueueTimestamp
timeSpecToDeltaQueueTimestamp ts =
  let s = fromIntegral $ sec ts + ntpOffset
      f = fromIntegral $ shiftR (nsec ts * nanoS) 32 in
  DeltaQueueTimestamp s f

deltaQueueTimestampStampToTimeSpec :: DeltaQueueTimestamp -> TimeSpec
deltaQueueTimestampStampToTimeSpec ts =
  let s = (fromIntegral $ dqtSec ts) - ntpOffset
      f = ((shiftL (fromIntegral $ dqtFrac ts) 32) `div` nanoS) in
  TimeSpec s f

timestampOffset :: DeltaQueueTimestamp -> IO Int
timestampOffset ts = do
    let tsX = deltaQueueTimestampStampToTimeSpec ts

    tsN <- getTime Realtime
    let diffX = diffTimeSpec tsX tsN
    --printf "diff %s now %s tsX %s\n" (show diffX) (show ts) (show tsX)
    return $ fromIntegral $ toNanoSecs $ diffX





