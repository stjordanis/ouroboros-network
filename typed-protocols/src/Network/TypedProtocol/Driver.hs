{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NamedFieldPuns #-}

--TODO: just temporary while hacking:

-- |
-- = Driving a Peer by was of a Duplex and Channel
--
-- A 'Duplex' allows for sending and receiving pieces of some concrete type.
-- In applications, this will probably be some sort of socket. In order to
-- use it to drive a typed protocol application (represented by a 'Peer'),
-- there must be a way to encode typed transitions of that protocol to the
-- concrete type, and to parse pieces of that concrete type incrementally into
-- a typed transition. This is defined by a 'Codec'.
--
-- A 'Codec' and a 'Duplex' alone is not enough to do encoding and decoding,
-- because the 'Codec' does not make any /decisions/ about the way in which
-- the protocol application progresses. It defines encodings for /all/ possible
-- transitions from a state, and an inverse for that encoder. It's the 'Peer'
-- term which decides which transitions to encode, thereby leading the 'Codec'
-- through a path in the protocol type.
--
-- Driving a 'Peer' in this way may give rise to an exception, given by
-- @'Unexpected' :: 'Result' t@.

module Network.TypedProtocol.Driver where

import           Data.Void (absurd)

import           Network.TypedProtocol.Core      as Core
import           Network.TypedProtocol.Pipelined (PeerSender, PeerReceiver)
import qualified Network.TypedProtocol.Pipelined as Pipelined
import           Network.TypedProtocol.Channel
import           Network.TypedProtocol.Codec (Codec (..), SomeMessage (..))
import qualified Network.TypedProtocol.Codec     as Codec

import           Control.Monad.Class.MonadSTM


-- | The 'connect' function takes two peers that agree on a protocol and runs
-- them in lock step, until (and if) they complete.  The first argument is
-- bunch of proofs that certain conditions will never happen: both client and
-- server are listening or awaiting (which results in a deadlock), nor one side
-- could finish without the other part to agree on it.
--
-- The 'connect' function serves a few purposes.
--
-- * The fact we can define this function at at all proves some minimal
-- sanity property of the typed protocol framework.
--
-- * It demonstrates that all protocols defined in the framework can be run
-- with synchronous communication rather than requiring buffered communication.
--
-- * It is useful for testing peer implementations against each other in a
-- minimalistic setting. The typed framework guarantees
--
-- * Prove that protocol state machine does not have a deadlock and that both
-- peers finish the protocol at the same moment.
--
connect :: Monad m
        => ImpossibleProofs ps
        -> Peer AsClient (st :: ps) m a
        -> Peer AsServer (st :: ps) m b
        -> m (a, b)
connect p (Effect a) b  = a >>= \a' -> connect p a' b
connect p a  (Effect b) = b >>= \b' -> connect p a  b'
connect _part (Done _ a) (Done _ b) = return (a, b)
connect p (Yield _ msg a) (Await _ b) = connect p a (b msg)
connect p (Await _ a) (Yield _ msg b) = connect p (a msg) b

connect ImpossibleProofs{notPartiallyFinished} (Done sd _) (Yield sy _ _) =  absurd (notPartiallyFinished sd (Right sy))
connect ImpossibleProofs{notPartiallyFinished} (Yield sy _ _) (Done sd _) = absurd $ notPartiallyFinished sd (Left sy)
connect ImpossibleProofs{notPartiallyFinished} (Done sd _) (Await sa _) = absurd $ notPartiallyFinished sd (Left sa)
connect ImpossibleProofs{notPartiallyFinished} (Await sa _) (Done sd _) = absurd $ notPartiallyFinished sd (Right sa)
connect ImpossibleProofs{noYieldingDeadlock} (Yield sy _ _) (Yield sy' _ _) = absurd $ noYieldingDeadlock sy sy'
connect ImpossibleProofs{noAwaitingDeadlock} (Await sa _) (Await sa' _) = absurd $ noAwaitingDeadlock sa' sa

runPeer
  :: forall ps (st :: ps) pk failure bytes m a .
     Monad m
  => Codec pk ps failure m bytes
  -> Channel m bytes
  -> Peer pk st m a
  -> m a

runPeer codec channel (Core.Effect k) =
    k >>= runPeer codec channel

runPeer _codec _channel (Core.Done _ x) =
    return x

runPeer codec@Codec{encode} Channel{send} (Core.Yield tok msg k) = do
    channel' <- send (encode tok msg)
    runPeer codec channel' k

runPeer codec@Codec{decode} channel (Core.Await stok k) = do
    decoder <- decode stok
    res <- runDecoder channel decoder
    case res of
      Right (SomeMessage msg, channel') -> runPeer codec channel' (k msg)
      Left failure                      -> undefined


runDecoder :: Monad m
           => Channel m bytes
           -> Codec.DecodeStep bytes failure m a
           -> m (Either failure (a, Channel m bytes))

runDecoder channel (Codec.Done x Nothing) =
    return (Right (x, channel))

runDecoder channel (Codec.Done x (Just trailing)) =
    return (Right (x, prependChannelRecv trailing channel))

runDecoder _channel (Codec.Fail failure) =
    return (Left failure)

runDecoder Channel{recv} (Codec.Partial k) = do
    (minput, channel') <- recv
    runDecoder channel' =<< k minput


runPipelinedPeer
  :: forall ps (st :: ps) pk failure bytes m a.
     MonadSTM m
  => Codec pk ps failure m bytes
  -> Channel m bytes
  -> Pipelined.PeerSender pk st m a
  -> m a
runPipelinedPeer codec channel peer = do
    queue <- atomically $ newTBQueue 10  --TODO: size?
    fork $ manageReceiverQueue queue channel
    runPipelinedPeerSender queue codec channel peer
  where
    --TODO: here we're forking the channel, which breaks it's invariants
    manageReceiverQueue queue channel = do
      ReceiveHandler receiver <- atomically (readTBQueue queue)
      channel' <- runPipelinedPeerReceiver codec channel receiver
      manageReceiverQueue queue channel'


data ReceiveHandler pk ps m where
     ReceiveHandler :: PeerReceiver pk (st :: ps) (st' :: ps) m
                    -> ReceiveHandler pk ps m


runPipelinedPeerSender
  :: forall ps (st :: ps) pk failure bytes m a.
     MonadSTM m
  => TBQueue m (ReceiveHandler pk ps m)
  -> Codec pk ps failure m bytes
  -> Channel m bytes
  -> PeerSender pk st m a
  -> m a
runPipelinedPeerSender queue Codec{encode} = go
  where
    go :: forall st'.
          Channel m bytes
       -> PeerSender pk st' m a
       -> m a
    go  channel (Pipelined.Effect k) = k >>= go channel

    go _channel (Pipelined.Done   x) = return x

    go Channel{send} (Pipelined.Yield msg receiver k) = do
      atomically (writeTBQueue queue (ReceiveHandler receiver))
      -- TODO: the token will come from `Piplined.Yield` constructor
      channel' <- send (encode undefined msg)
      go channel' k


runPipelinedPeerReceiver
  :: forall ps (st :: ps) (st' :: ps) pk failure bytes m.
     Monad m
  => Codec pk ps failure m bytes
  -> Channel m bytes
  -> PeerReceiver pk (st :: ps) (st' :: ps) m
  -> m (Channel m bytes)
runPipelinedPeerReceiver Codec{decode} = go
  where
    go :: forall st st'.
          Channel m bytes
       -> PeerReceiver pk st st' m
       -> m (Channel m bytes)
    go channel (Pipelined.Effect' k) = k >>= go channel

    go channel Pipelined.Completed = return channel

    go channel (Pipelined.Await stok k) = do
      decoder <- decode stok
      res <- runDecoder channel decoder
      case res of
        Right (SomeMessage msg, channel') -> go channel' (k msg)
        Left failure                      -> undefined

