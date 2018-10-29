{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Socket where

import           Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import           Control.Concurrent.STM
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.ST (RealWorld, stToIO)

import           Chain (Chain, ChainUpdate)
import qualified Chain
import           ChainProducerState as ChainProducer (ChainProducerState,
                     ReaderId, applyChainUpdate, initChainProducerState)
import           ConsumersAndProducers
import           Protocol
import           ProtocolInterfaces
import           Serialise

import qualified Codec.CBOR.Read as CBOR
import qualified Codec.CBOR.Write as CBOR
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import           Data.Word
import           Text.Printf

import           Network.Socket hiding (recv, recvFrom, send, sendTo)
import           Network.Socket.ByteString

data Conversation
    = ChainHeaderSync
    | PingPong
    deriving (Eq, Ord, Show)

encodeProtocolHeader :: Conversation -> Int -> BL.ByteString
encodeProtocolHeader conv len = Put.runPut enc
  where
    enc = do
        putConversation conv
        Put.putWord32be (fromIntegral len)

    putConversation ChainHeaderSync = Put.putWord16be 1
    putConversation PingPong        = Put.putWord16be 2

decodeProtocolHeader :: BL.ByteString -> Maybe (Conversation, Word32)
decodeProtocolHeader buf =
    case Get.runGetOrFail dec buf of
         Left  (_, _, _)  -> Nothing
         Right (_, _, ph) -> Just ph

  where
    dec = do
        convid <- Get.getWord16be
        len <- Get.getWord32be
        return (decodeConveration convid, len)

    decodeConveration 1 = ChainHeaderSync
    decodeConveration 2 = PingPong
    decodeConveration a = error $ "unknow conversation " ++ show a -- XXX

data ProtocolAction s r a
  = Send s (IO (ProtocolAction s r a))
  | Recv (r -> IO (ProtocolAction s r a))
  | Ping s (IO (ProtocolAction s r a))
  | Pong (r -> IO (ProtocolAction s r a))
  | Fail ProtocolFailure

data ProtocolFailure = ProtocolStopped
                     | ProtocolFailure String
  deriving Show

newtype Protocol s r a = Protocol {
       unwrapProtocol ::
         forall x. (a -> IO (ProtocolAction s r x)) -> IO (ProtocolAction s r x)
     }

instance Functor (Protocol s r) where
    fmap f a = a >>= return . f

instance Applicative (Protocol s r) where
    pure x = Protocol $ \k -> k x
    (<*>) = ap

instance Monad (Protocol s r) where
    return = pure

    {-# INLINE (>>=) #-}
    m >>= f = Protocol $ \k ->
                unwrapProtocol m $ \x ->
                  unwrapProtocol (f x) k

instance MonadIO (Protocol s r) where
    liftIO action = Protocol (\k -> action >>= k)

unProtocol :: Protocol s r a -> IO (ProtocolAction s r a)
unProtocol (Protocol k) = k (\_ -> return (Fail ProtocolStopped))

recvMsg :: Protocol s r r
recvMsg = Protocol (return . Recv)

sendMsg :: s -> Protocol s r ()
sendMsg msg = Protocol (\k -> return (Send msg (k ())))

protocolFailure :: ProtocolFailure -> Protocol s r a
protocolFailure failure = Protocol (\_k -> return (Fail failure))

----------------------------------------

example1 :: Protocol String Int ()
example1 = do
    sendMsg "hello"
    x <- recvMsg
    liftIO $ print x
    return ()

consoleProtocolAction :: (Show s, Show r, Read r)
                      => Protocol s r a -> IO ()
consoleProtocolAction a = unProtocol a >>= go
  where
    go (Send msg k) = do
      print ("Send", msg)
      k >>= go
    go (Recv k)     = do
      print "Recv"
      x <- readLn
      print ("Recv", x)
      k x >>= go
    go (Fail err) =
      print ("Fail", err)

demo1 :: IO ()
demo1 = consoleProtocolAction example1

-------------------------------------------

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
    producerVar <- newTVarIO (initChainProducerState chain0)
    consumerVar <- newTVarIO chain0

    -- Fork the producer and consumer
    ptids <- producer prodSock producerVar
    ctids <- consumer consSock' consumerVar

    -- Apply updates to the producer's chain and let them sync
    _ <- forkIO $ sequence_
           [ do threadDelay 1000 -- just to provide interest
                atomically $ do
                  p <- readTVar producerVar
                  let Just p' = ChainProducer.applyChainUpdate update p
                  writeTVar producerVar p'
           | update <- updates ]

    -- Wait until the consumer's chain syncs with the producers chain
    let Just expectedChain = Chain.applyChainUpdates updates chain0
    chain' <- atomically $ do
                chain' <- readTVar consumerVar
                check (Chain.headPoint expectedChain == Chain.headPoint chain')
                return chain'

    mapM_ killThread ptids
    mapM_ killThread ctids
    close prodSock
    close consSock
    close consSock'

    return (expectedChain == chain')

type ConsumerSideProtocol block = Protocol MsgConsumer (MsgProducer block)
type ProducerSideProtocol block = Protocol (MsgProducer block) MsgConsumer

producer :: forall block. (Chain.HasHeader block, Serialise block)
         => Socket -> TVar (ChainProducerState block) -> IO [ThreadId]
producer sd producerVar = do
    (wtid, wqueue) <- startupWriter sd
    startupReader wqueue sd [(ChainHeaderSync, producerSideProtocol)] [wtid] M.empty
  where
    -- Reuse the generic 'producerSideProtocol1'
    -- but interpret it in our Protocol free monad.
    producerSideProtocol :: ProducerSideProtocol block ()
    producerSideProtocol =
      producerSideProtocol1
        producerHandlers
        sendMsg
        recvMsg

    -- Reuse the generic 'exampleProducer'
    -- and lift it from IO to the Protocol monad
    producerHandlers :: ProducerHandlers block (ProducerSideProtocol block) ReaderId
    producerHandlers =
      liftProducerHandlers liftIO (exampleProducer producerVar)

consumer :: forall block. (Chain.HasHeader block, Serialise block)
         => Socket -> TVar (Chain block ) -> IO [ThreadId]
consumer sd chainVar = do
    (wtid, wqueue) <- startupWriter sd
    startupReader wqueue sd [(ChainHeaderSync, consumerSideProtocol)] [wtid] M.empty

  where
    -- Reuse the generic 'consumerSideProtocol1'
    -- but interpret it in our Protocol free monad.
    consumerSideProtocol :: ConsumerSideProtocol block ()
    consumerSideProtocol =
      consumerSideProtocol1
        consumerHandlers
        sendMsg
        recvMsg

    -- Reuse the generic 'exampleProducer'
    -- and lift it from IO to the Protocol monad
    consumerHandlers :: ConsumerHandlers block (ConsumerSideProtocol block)
    consumerHandlers =
      liftConsumerHandlers liftIO (exampleConsumer chainVar)





------------------------------------------------


runProtocolWithTBQueues :: forall smsg rmsg.  (Serialise smsg, Serialise rmsg)
                        => (BS.ByteString -> STM ())
                        -> STM BS.ByteString
                        -> Protocol smsg rmsg ()
                        -> IO ()
runProtocolWithTBQueues wqueue rqueue p =
    unProtocol p >>= go mempty
  where
    go trailing (Send msg k) = do
      let body = BL.toStrict $ CBOR.toLazyByteString (encode msg)
      atomically $ wqueue body
      k >>= go trailing

    go trailing (Recv k) = do
      mmsg <- decodeFromHandle trailing
                =<< stToIO (CBOR.deserialiseIncremental decode)
      case mmsg of
        Left failure           -> fail (show failure)
        Right (trailing', msg) -> k msg >>= go trailing'

    go _trailing (Fail failure) = fail (show failure)

    decodeFromHandle :: BS.ByteString
                     -> CBOR.IDecode RealWorld rmsg
                     -> IO (Either CBOR.DeserialiseFailure
                                   (BS.ByteString, rmsg))

    decodeFromHandle _trailing (CBOR.Done trailing' _off msg) =
      return (Right (trailing', msg))

    decodeFromHandle _trailing (CBOR.Fail _trailing' _off failure) =
      return (Left failure)

    decodeFromHandle trailing (CBOR.Partial k) | not (BS.null trailing) =
      stToIO (k (Just trailing)) >>= decodeFromHandle mempty

    decodeFromHandle _ (CBOR.Partial k) = do
      chunk <- atomically rqueue
      stToIO (k (if BS.null chunk then Nothing else Just chunk))
        >>= decodeFromHandle mempty

startupWriter :: Socket -> IO (ThreadId, TBQueue (Conversation, BS.ByteString))
startupWriter sd = do
    queue <- atomically $ newTBQueue 64
    tid <- forkIO (socketWriter (readTBQueue queue) sd)
    return (tid, queue)

startupConversation :: forall smsg rmsg.  (Serialise smsg, Serialise rmsg)
                     => TBQueue (Conversation, BS.ByteString)
                     -> (Conversation, Protocol smsg rmsg ())
                     -> IO (ThreadId, Conversation, TBQueue BS.ByteString)
startupConversation wqueue (conv, p) = do
    queue <- atomically $ newTBQueue 64 -- XXX Should depend on protocol definition
    let rqueue = readTBQueue queue
    let wqueue' a = writeTBQueue wqueue (conv, a)
    tid <- forkIO $ runProtocolWithTBQueues wqueue' rqueue p
    return (tid, conv, queue)

startupReader :: forall smsg rmsg.  (Serialise smsg, Serialise rmsg)
              => TBQueue (Conversation, BS.ByteString)
              -> Socket
              -> [(Conversation, Protocol smsg rmsg ())]
              -> [ThreadId]
              -> M.Map Conversation (TBQueue BS.ByteString)
              -> IO [ThreadId]
startupReader _ sd [] tids m = do
    tid <- forkIO $ socketReader m sd
    return $ tid : tids
startupReader wqueue sd (p:ps) tids m = do
    (tid, c, q) <- startupConversation wqueue p
    startupReader wqueue sd ps (tid:tids) (M.insert c q m)

socketWriter :: STM (Conversation, BS.ByteString)
             -> Socket
             -> IO ()
socketWriter rqueue sd =
    forever $ do
        (conv, blob) <- atomically rqueue
        let header = encodeProtocolHeader conv $ BS.length blob
        -- printf "writing header %s %d\n" (show conv) (BS.length blob)
        sendAll sd $ BL.toStrict header
        -- printf "writing blob\n"
        sendAll sd blob

socketReader :: M.Map Conversation (TBQueue BS.ByteString)
             -> Socket
             -> IO ()
socketReader wqueueMap sd =
    forever $ do
        header <- recvLen' 6 []
        case decodeProtocolHeader (BL.fromStrict header) of
             Nothing -> error "failed to decode header"
             Just (convId, len) ->
                 case M.lookup convId wqueueMap of
                      Nothing     -> error $ "unknown conversation " ++ show convId -- XXX
                      Just wqueue -> do
                          blob <- recvLen' (fromIntegral len) []
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

pongSideProtocol1
  :: forall m.
     Monad m
  => (Word64 -> m ()) -- ^ send
  -> m Word64       -- ^ recv
  -> m ()
pongSideProtocol1 s r =
    forever $ do
        ts <- r
        s $ 234 - ts

pingSideProtocol1
  :: forall m.
     Monad m
  => (Word64 -> m ()) -- ^ send
  -> m Word64       -- ^ recv
  -> m ()
pingSideProtocol1 s r =
    forever $ do
        s 123
        _ <- r
        return ()
