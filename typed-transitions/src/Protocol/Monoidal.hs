{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Protocol.Monoidal where

import Prelude hiding (product)

import Control.Monad.Class.MonadFork (MonadFork (..))
import Control.Monad.Class.MonadSTM (MonadSTM (..))
import Data.Kind (Type)
import Protocol.Core

data PeerTuple (ps :: (Type, Type)) (trs :: (st -> st -> Type, st' -> st' -> Type)) (from :: (Status st, Status st')) (to :: (Status st, Status st')) f (a :: (Type, Type)) where
  PeerTuple
    :: Peer p tr (from :: Status st) (to :: Status st) f a
    -> Peer p' tr' (from' :: Status st') (to' :: Status st') f a'
    -> PeerTuple '(p, p') '(tr, tr') '(from, from') '(to, to') f '(a, a')

connectBoth
  :: forall (ps :: (Type, Type)) (trs :: (st -> st -> Type, st' -> st' -> Type)) start start' end end' m a a' b b'.
     MonadSTM m
  => PeerTuple ps trs '(start, start') end m '(a, a')
  -> PeerTuple ps trs '(Complement start, Complement start') end' m '(b, b')
  -> m (Those a b, Those a' b')
connectBoth (PeerTuple p r) (PeerTuple p' r') = do
  resVar  <- atomically $ newEmptyTMVar
  resVar' <- atomically $ newEmptyTMVar

  fork $ do
    res <- connect p p'
    atomically $ putTMVar resVar res
  fork $ do
    res' <- connect r r'
    atomically $ putTMVar resVar' res'

  res  <- atomically $ readTMVar resVar
  res' <- atomically $ readTMVar resVar'
  return (res, res')
