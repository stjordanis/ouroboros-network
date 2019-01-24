{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NamedFieldPuns #-}

{-# OPTIONS_GHC -Wall -Wno-unticked-promoted-constructors #-}

-- | This module defines the core of the typed protocol framework.
--
-- The typed protocol framework is used to define, test and execute protocols.
-- It also provides some abstractions for untyped channels and for encoding and
-- decoding protocol messages from untyped channels.
--
-- The typed protocol framework guarantees:
--
-- * agreement on which messages can be sent and received;
-- * the absence of race conditions; and
-- * the absence of deadlock.
--
-- It is a simple form of session typing. The trade-off to achieve these
-- guarantees it that places constraints on the kinds of protocol that can be
-- expressed. In particular it requires that protocols be defined as a state
-- transition system. It requires for each protocol state that one of the two
-- peers be able to send and the other must be ready to receive.
--
-- This means it is not possible to express protocols such as TCP where there
-- are protocol states where a single peer can both send and receive, however
-- it is suitable for most application-level protocols. In particular many
-- application-level protocols are completely in-order and synchronous.
--
-- In many (but not all) cases it is also possible to pipeline these protocols
-- so that network latency can be hidden and full use made of the available
-- bandwidth. Special support is provided to run protocols in a pipelined way,
-- without having to change the protocol definition.
--
-- The protocols in this framework assume an underlying \"reliable ordered\"
-- connection. A \"reliable ordered\" connection is a term of art means one
-- where the receiving end receives any prefix of the messages sent by the
-- sending end. It is not reliable in the colloquial sense as it does not
-- ensure that anything actually arrives, only that /if/ any message arrives,
-- all the previous ones did too, and in the order in which they were sent.
--
module Network.TypedProtocol.Pipelined where

import           Data.Void (absurd)

import           Network.TypedProtocol.Core
  ( Agency (..)
  , CurrentAgency
  , CurrentToken
  , FlipPeer
  , Protocol (..)
  , PeerKind
  , ImpossibleProofs (..)
  )
import qualified Network.TypedProtocol.Core as Core



data PeerSender (pk :: PeerKind) (st :: ps) m a where

  Effect :: m (PeerSender pk st m a)
         ->    PeerSender pk st m a

  Done   :: (CurrentAgency pk (AgencyInState st) ~ Finished)
         => TerminalToken st
         -> a
         -> PeerSender pk st m a

  Yield  :: (CurrentAgency pk (AgencyInState st) ~ Yielding)
         => CurrentToken pk st
         -> Message st st'
         -> PeerReceiver pk (st'  :: ps) (st'' :: ps) m
         -> PeerSender   pk (st'' :: ps) m a
         -> PeerSender   pk (st   :: ps) m a

effect
  :: m (PeerSender pk st m a)
  -> PeerSender pk st m a
effect = Effect

done
  :: (CurrentAgency pk (AgencyInState st) ~ Finished)
  => TerminalToken st
  -> a
  -> PeerSender pk st m a
done = Done

yield
  :: (CurrentAgency pk (AgencyInState st) ~ Yielding)
  => CurrentToken pk st
  -> Message st st'
  -> PeerReceiver pk (st'  :: ps) (st'' :: ps) m
  -> PeerSender   pk (st'' :: ps) m a
  -> PeerSender   pk (st   :: ps) m a
yield = Yield

complete
  :: ( CurrentAgency pk (AgencyInState st) ~ Yielding
     , CurrentAgency pk (AgencyInState st') ~ Finished
     )
  => CurrentToken pk st
  -> TerminalToken st'
  -> Message st st'
  -> a
  -> PeerSender   pk (st  :: ps) m a
complete tok tok' msg a = yield tok msg Completed (done tok' a)

data PeerReceiver (pk :: PeerKind) (st :: ps) (st' :: ps) m where

  Effect'   :: m (PeerReceiver pk st st' m)
            ->    PeerReceiver pk st st' m

  Completed :: PeerReceiver pk st st m

  Await     :: (CurrentAgency pk (AgencyInState st) ~ Awaiting)
            => CurrentToken (FlipPeer pk) st
            -> (forall st''. Message st st'' -> PeerReceiver pk st'' st' m)
            -> PeerReceiver pk st st' m

effect'
  :: m (PeerReceiver pk st st' m)
  ->    PeerReceiver pk st st' m
effect' = Effect'

await
  :: (CurrentAgency pk (AgencyInState st) ~ Awaiting)
  => CurrentToken (FlipPeer pk) st
  -> (forall st''. Message st st'' -> PeerReceiver pk st'' st' m)
  -> PeerReceiver pk st st' m
await = Await

-- |
-- Like `Network.Protocol.Core.connect` but for pipelined sender.
-- Note that this function sequencialises the pipelining and runs it in
-- a single thread.
--
connect
  :: forall (st :: ps) m a b. Monad m
  => ImpossibleProofs ps
  -> PeerSender Core.AsClient st m a
  -> Core.Peer Core.AsServer st m b
  -> m (a, b)
connect p (Effect a) b = a >>= \a' -> connect p a' b
connect p a (Core.Effect b) = b >>= \b' -> connect p a b'
connect _ (Done _ a) (Core.Done _ b) = return (a, b)
connect p (Yield _ msg receiver a) (Core.Await _ b) = do
  b' <- connectReceiver receiver (b msg)
  connect p a b'
 where
  connectReceiver
    :: PeerReceiver Core.AsClient st0 st1 m
    -> Core.Peer Core.AsServer st0 m b
    -> m (Core.Peer Core.AsServer st1 m b)
  connectReceiver (Effect' x) y = x >>= \x' -> connectReceiver x' y
  connectReceiver x (Core.Effect y) = y >>= \y' -> connectReceiver x y'
  connectReceiver Completed y = return y
  connectReceiver (Await _tok x) (Core.Yield _ msg_ y) = connectReceiver (x msg_) y
  -- forbidden cases
  connectReceiver (Await sa _) (Core.Await sa' _) = absurd $ noAwaitingDeadlock p sa' sa
  connectReceiver (Await sa _) (Core.Done sd _) = absurd $ notPartiallyFinished p sd (Right sa)
-- forbidden cases
connect ImpossibleProofs{notPartiallyFinished} (Done sd _) (Core.Yield sy _ _) =  absurd (notPartiallyFinished sd (Right sy))
connect ImpossibleProofs{notPartiallyFinished} (Yield sy _ _ _) (Core.Done sd _) = absurd $ notPartiallyFinished sd (Left sy)
connect ImpossibleProofs{notPartiallyFinished} (Done sd _) (Core.Await sa _) = absurd $ notPartiallyFinished sd (Left sa)
connect ImpossibleProofs{noYieldingDeadlock} (Yield sy _ _ _) (Core.Yield sy' _ _) = absurd $ noYieldingDeadlock sy sy'
