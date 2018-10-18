{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module Socket where

import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.ST (stToIO, RealWorld)
import           Control.Concurrent.STM
import           Control.Concurrent (forkIO, killThread, threadDelay)

import           Chain (Chain, ChainUpdate)
import qualified Chain
import           Serialise
import           ProtocolInterfaces
import           Protocol
import           ConsumersAndProducers
import           ChainProducerState as ChainProducer
                   ( ChainProducerState, ReaderId
                   , initChainProducerState, applyChainUpdate )

import qualified Data.ByteString         as  BS
import qualified Codec.CBOR.Read  as CBOR
import qualified Codec.CBOR.Write as CBOR

import           Network.Socket hiding (send, sendTo, recv, recvFrom)
import           Network.Socket.ByteString

data ProtocolAction s r a
  = Send s (IO (ProtocolAction s r a))
  | Recv (r -> IO (ProtocolAction s r a))
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
recvMsg = Protocol (\k -> return (Recv (\msg -> k msg)))

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
    ptid <- forkIO $ producer prodSock producerVar
    ctid <- forkIO $ consumer consSock' consumerVar

    -- Apply updates to the producer's chain and let them sync
    _ <- forkIO $ sequence_
           [ do threadDelay 1000 -- just to provide interest
                atomically $ do
                  p <- readTVar producerVar
                  let Just p' = ChainProducer.applyChainUpdate update p
                  writeTVar producerVar p'
           | update <- updates ]

    -- Wait until the consumer's chain syncs with the producer's chain
    let Just expectedChain = Chain.applyChainUpdates updates chain0
    chain' <- atomically $ do
                chain' <- readTVar consumerVar
                check (Chain.headPoint expectedChain == Chain.headPoint chain')
                return chain'

    killThread ptid
    killThread ctid
    close prodSock
    close consSock
    close consSock'

    return (expectedChain == chain')

type ConsumerSideProtocol block = Protocol MsgConsumer (MsgProducer block)
type ProducerSideProtocol block = Protocol (MsgProducer block) MsgConsumer

producer :: forall block. (Chain.HasHeader block, Serialise block)
         => Socket -> TVar (ChainProducerState block) -> IO ()
producer sd producerVar = do
    runProtocolWithSocket
      sd
      producerSideProtocol
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
         => Socket -> TVar (Chain block ) -> IO ()
consumer sd chainVar =
    runProtocolWithSocket
      sd
      consumerSideProtocol
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

runProtocolWithSocket :: forall smsg rmsg.
                       (Serialise smsg, Serialise rmsg)
                    => Socket
                    -> Protocol smsg rmsg ()
                    -> IO ()
runProtocolWithSocket sd p =
    unProtocol p >>= go mempty
  where
    go trailing (Send msg k) = do
      _ <- send sd $ CBOR.toStrictByteString (encode msg)
      k >>= go trailing

    go trailing (Recv k) = do
      mmsg <- decodeFromHandle trailing
                =<< stToIO (CBOR.deserialiseIncremental decode)
      case mmsg of
        Left failure -> fail (show failure)
        Right (trailing', msg) -> do
          k msg >>= go trailing'

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
      chunk <- recv sd 0xffff
      stToIO (k (if BS.null chunk then Nothing else Just chunk))
        >>= decodeFromHandle mempty

