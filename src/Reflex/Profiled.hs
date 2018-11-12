{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
module Reflex.Profiled where

import Control.Lens hiding (children)
import Control.Monad
import Control.Monad.Exception
import Control.Monad.Fix
import Control.Monad.Primitive
import Control.Monad.Reader
import Control.Monad.Ref
import Control.Monad.State.Strict (StateT, execStateT, modify)
import Data.Bifunctor
import Data.Coerce
import Data.Dependent.Map (DMap, GCompare)
import Data.FastMutableIntMap
import Data.IORef
import Data.List
import Data.Map (Map)
import qualified Data.Map.Strict as Map
import Data.Monoid ((<>))
import Data.Ord
import qualified Data.Semigroup as S
import Data.Type.Coercion
import Foreign.Ptr
import GHC.Foreign
import GHC.IO.Encoding
import GHC.Stack
import Reflex.Class
import Reflex.Host.Class
import Reflex.PerformEvent.Class

import System.IO.Unsafe
import Unsafe.Coerce

data ProfiledTimeline t

{-# NOINLINE profilingData #-}
profilingData :: IORef (Map (Ptr CostCentreStack) Int)
profilingData = unsafePerformIO $ newIORef Map.empty

data CostCentreTree = CostCentreTree
  { _costCentreTree_ownEntries :: !Int
  , _costCentreTree_cumulativeEntries :: !Int
  , _costCentreTree_children :: !(Map (Ptr CostCentre) CostCentreTree)
  }
  deriving (Show, Eq, Ord)

instance S.Semigroup CostCentreTree where
  (CostCentreTree oa ea ca) <> (CostCentreTree ob eb cb) =
      CostCentreTree (oa + ob) (ea + eb) $ Map.unionWith (S.<>) ca cb

instance Monoid CostCentreTree where
  mempty = CostCentreTree 0 0 mempty
  mappend = (S.<>)

getCostCentreStack :: Ptr CostCentreStack -> IO [Ptr CostCentre]
getCostCentreStack = go []
  where go l ccs = if ccs == nullPtr
          then return l
          else do
          cc <- ccsCC ccs
          parent <- ccsParent ccs
          go (cc : l) parent

toCostCentreTree :: Ptr CostCentreStack -> Int -> IO CostCentreTree
toCostCentreTree ccs n = do
  ccList <- getCostCentreStack ccs
  return $ foldr (\cc child -> CostCentreTree 0 n $ Map.singleton cc child) (CostCentreTree n n mempty) ccList

getCostCentreTree :: IO CostCentreTree
getCostCentreTree = do
  vals <- readIORef profilingData
  mconcat <$> mapM (uncurry toCostCentreTree) (Map.toList vals)

formatCostCentreTree :: CostCentreTree -> IO String
formatCostCentreTree cct0 = unlines . reverse <$> execStateT (go 0 cct0) []
  where go :: Int -> CostCentreTree -> StateT [String] IO ()
        go depth cct = do
          let children = sortOn (Down . _costCentreTree_cumulativeEntries . snd) $ Map.toList $ _costCentreTree_children cct
              indent = mconcat $ replicate depth "  "
          forM_ children $ \(cc, childCct) -> do
            lbl <- liftIO $ peekCString utf8 =<< ccLabel cc
            mdl <- liftIO $ peekCString utf8 =<< ccModule cc
            loc <- liftIO $ peekCString utf8 =<< ccSrcSpan cc
            let description = mdl <> "." <> lbl <> " (" <> loc <> ")"
            modify $ (:) $ indent <> description <> "\t" <> show (_costCentreTree_cumulativeEntries childCct) <> "\t" <> show (_costCentreTree_ownEntries childCct)
            go (succ depth) childCct

showProfilingData :: IO ()
showProfilingData = do
  putStr =<< formatCostCentreTree =<< getCostCentreTree

writeProfilingData :: FilePath -> IO ()
writeProfilingData p = do
  writeFile p =<< formatCostCentreTree =<< getCostCentreTree

newtype ProfiledM m a = ProfiledM { runProfiledM :: m a }
  deriving (Functor, Applicative, Monad, MonadFix, MonadException, MonadAsyncException)

profileEvent :: Reflex t => Event t a -> Event t a
profileEvent e = unsafePerformIO $ do
  stack <- getCurrentCCS e
  let f x = unsafePerformIO $ do
        modifyIORef' profilingData $ Map.insertWith (+) stack 1
        return $ return $ Just x
  return $ pushCheap f e

--TODO: Instead of profiling just the input or output of each one, profile all the inputs and all the outputs

instance Reflex t => Reflex (ProfiledTimeline t) where
  newtype Behavior (ProfiledTimeline t) a = Behavior_Profiled { unBehavior_Profiled :: Behavior t a }
  newtype Event (ProfiledTimeline t) a = Event_Profiled { unEvent_Profiled :: Event t a }
  newtype Dynamic (ProfiledTimeline t) a = Dynamic_Profiled { unDynamic_Profiled :: Dynamic t a }
  newtype Incremental (ProfiledTimeline t) p = Incremental_Profiled { unIncremental_Profiled :: Incremental t p }
  newtype Cell (ProfiledTimeline t) f = Cell_Profiled (Cell t f)
  newtype FanCell (ProfiledTimeline t) x = FanCell_Profiled (FanCell t x)
  type PushM (ProfiledTimeline t) = ProfiledM (PushM t)
  type PullM (ProfiledTimeline t) = ProfiledM (PullM t)
  newtype CellBuilderM (ProfiledTimeline t) x a = CellBuilderM_Profiled { unCellBuilderM_Profiled :: CellBuilderM t x a }
  newtype CellM (ProfiledTimeline t) x a = CellM_Profiled { unCellM_Profiled :: CellM t x a }
  newtype CellTrigger (ProfiledTimeline t) a x = CellTrigger_Profiled { unCellTrigger_Profiled :: CellTrigger t a x}
  never = Event_Profiled never
  constant = Behavior_Profiled . constant
  push f (Event_Profiled e) = coerce $ push (coerce f) $ profileEvent e -- Profile before rather than after; this way fanout won't count against us
  pushCheap f (Event_Profiled e) = coerce $ pushCheap (coerce f) $ profileEvent e
  pull = Behavior_Profiled . pull . coerce
  merge :: forall k. GCompare k => DMap k (Event (ProfiledTimeline t)) -> Event (ProfiledTimeline t) (DMap k Identity)
  merge = Event_Profiled . merge . (unsafeCoerce :: DMap k (Event (ProfiledTimeline t)) -> DMap k (Event t))
  fan (Event_Profiled e) = EventSelector $ coerce $ select (fan $ profileEvent e)
  switch (Behavior_Profiled b) = coerce $ profileEvent $ switch (coerceBehavior b)
  coincidence (Event_Profiled e) = coerce $ profileEvent $ coincidence (coerceEvent e)
  current (Dynamic_Profiled d) = coerce $ current d
  updated (Dynamic_Profiled d) = coerce $ profileEvent $ updated d
  unsafeBuildDynamic (ProfiledM a0) (Event_Profiled a') = coerce $ unsafeBuildDynamic a0 a'
  unsafeBuildIncremental (ProfiledM a0) (Event_Profiled a') = coerce $ unsafeBuildIncremental a0 a'
  mergeIncremental = Event_Profiled . mergeIncremental . (unsafeCoerce :: Incremental (ProfiledTimeline t) (PatchDMap k (Event (ProfiledTimeline t))) -> Incremental t (PatchDMap k (Event t)))
  mergeIncrementalWithMove = Event_Profiled . mergeIncrementalWithMove . (unsafeCoerce :: Incremental (ProfiledTimeline t) (PatchDMapWithMove k (Event (ProfiledTimeline t))) -> Incremental t (PatchDMapWithMove k (Event t)))
  currentIncremental (Incremental_Profiled i) = coerce $ currentIncremental i
  updatedIncremental (Incremental_Profiled i) = coerce $ profileEvent $ updatedIncremental i
  incrementalToDynamic (Incremental_Profiled i) = coerce $ incrementalToDynamic i
  behaviorCoercion (c :: Coercion a b) = case behaviorCoercion c :: Coercion (Behavior t a) (Behavior t b) of
    Coercion -> unsafeCoerce (Coercion :: Coercion (Behavior (ProfiledTimeline t) a) (Behavior (ProfiledTimeline t) a)) --TODO: Figure out how to make this typecheck without the unsafeCoerce
  eventCoercion (c :: Coercion a b) = case eventCoercion c :: Coercion (Event t a) (Event t b) of
    Coercion -> unsafeCoerce (Coercion :: Coercion (Event (ProfiledTimeline t) a) (Event (ProfiledTimeline t) a)) --TODO: Figure out how to make this typecheck without the unsafeCoerce
  dynamicCoercion (c :: Coercion a b) = case dynamicCoercion c :: Coercion (Dynamic t a) (Dynamic t b) of
    Coercion -> unsafeCoerce (Coercion :: Coercion (Dynamic (ProfiledTimeline t) a) (Dynamic (ProfiledTimeline t) a)) --TODO: Figure out how to make this typecheck without the unsafeCoerce
  mergeIntIncremental = Event_Profiled . mergeIntIncremental . (unsafeCoerce :: Incremental (ProfiledTimeline t) (PatchIntMap (Event (ProfiledTimeline t) a)) -> Incremental t (PatchIntMap (Event t a)))
  fanInt (Event_Profiled e) = coerce $ fanInt $ profileEvent e

instance Reflex t => CreateCellEvent (ProfiledTimeline t) (CellBuilderM (ProfiledTimeline t)) where
  newCellEvent = coerce <$> CellBuilderM_Profiled newCellEvent

instance Reflex t => CreateCellEvent (ProfiledTimeline t) (CellM (ProfiledTimeline t)) where
  newCellEvent = coerce <$> CellM_Profiled newCellEvent

instance Reflex t => FireCellEvent (ProfiledTimeline t) (CellM (ProfiledTimeline t)) where
  fireCellEvent (CellTrigger_Profiled t) o = CellM_Profiled $ fireCellEvent t o

deriving instance Functor (Dynamic t) => Functor (Dynamic (ProfiledTimeline t))
deriving instance Applicative (Dynamic t) => Applicative (Dynamic (ProfiledTimeline t))
deriving instance Monad (Dynamic t) => Monad (Dynamic (ProfiledTimeline t))


instance Reflex t => Functor (CellBuilderM (ProfiledTimeline t) x) where
  fmap = withMonadCellBuilderM @t fmap

instance Reflex t => Applicative (CellBuilderM (ProfiledTimeline t) x) where
  pure = withMonadCellBuilderM @t pure
  (<*>) = withMonadCellBuilderM @t (<*>)
  (*>) = withMonadCellBuilderM @t (*>)
  (<*) = withMonadCellBuilderM @t (<*)

instance Reflex t => Monad (CellBuilderM (ProfiledTimeline t) x) where
  (>>=) = withMonadCellBuilderM @t (>>=)
  (>>) = withMonadCellBuilderM @t (>>)
  return = withMonadCellBuilderM @t return
  fail = withMonadCellBuilderM @t fail

instance Reflex t => Functor (CellM (ProfiledTimeline t) x) where
  fmap = withMonadCellM @t fmap

instance Reflex t => Applicative (CellM (ProfiledTimeline t) x) where
  pure = withMonadCellM @t pure
  (<*>) = withMonadCellM @t (<*>)
  (*>) = withMonadCellM @t (*>)
  (<*) = withMonadCellM @t (<*)

instance Reflex t => Monad (CellM (ProfiledTimeline t) x) where
  (>>=) = withMonadCellM @t (>>=)
  (>>) = withMonadCellM @t (>>)
  return = withMonadCellM @t return
  fail = withMonadCellM @t fail

instance (Reflex t, MonadHold t m) => MonadHold (ProfiledTimeline t) (ProfiledM m) where
  hold v0 (Event_Profiled v') = ProfiledM $ Behavior_Profiled <$> hold v0 v'
  holdDyn v0 (Event_Profiled v') = ProfiledM $ Dynamic_Profiled <$> holdDyn v0 v'
  holdIncremental v0 (Event_Profiled v') = ProfiledM $ Incremental_Profiled <$> holdIncremental v0 v'
  buildDynamic (ProfiledM v0) (Event_Profiled v') = ProfiledM $ Dynamic_Profiled <$> buildDynamic v0 v'
  headE (Event_Profiled e) = ProfiledM $ Event_Profiled <$> headE e
  holdPushCell (Event_Profiled e) build update = ProfiledM $ first Cell_Profiled <$> holdPushCell e (coerce build) (coerce update)
  withHoldFanCell' = hoistLinear' ProfiledM $ mapLinear' FanCell_Profiled (\(FanCellEvent (Event_Profiled e)) -> FanCellEvent $ fmapCheap unCellM_Profiled e) id withHoldFanCell'

instance (Reflex t, MonadMutate t m) => MonadMutate (ProfiledTimeline t) (ProfiledM m) where
  mutateFanCell (FanCell_Profiled c) (CellBuilderM_Profiled a) = ProfiledM $ mutateFanCell c a

instance MonadSample t m => MonadSample (ProfiledTimeline t) (ProfiledM m) where
  sample (Behavior_Profiled b) = ProfiledM $ sample b

instance MonadTrans ProfiledM where
  lift = ProfiledM

instance MonadIO m => MonadIO (ProfiledM m) where
  liftIO = lift . liftIO

instance PerformEvent t m => PerformEvent (ProfiledTimeline t) (ProfiledM m) where
  type Performable (ProfiledM m) = Performable m
  performEvent_ = lift . performEvent_ . coerce
  performEvent = lift . fmap coerce . performEvent . coerce

instance MonadRef m => MonadRef (ProfiledM m) where
  type Ref (ProfiledM m) = Ref m
  newRef = lift . newRef
  readRef = lift . readRef
  writeRef r = lift . writeRef r

instance MonadReflexCreateTrigger t m => MonadReflexCreateTrigger (ProfiledTimeline t) (ProfiledM m) where
  newEventWithTrigger = lift . fmap coerce . newEventWithTrigger
  newFanEventWithTrigger f = do
    es <- lift $ newFanEventWithTrigger f
    return $ EventSelector $ \k -> coerce $ select es k

instance MonadReader r m => MonadReader r (ProfiledM m) where
  ask = lift ask
  local f (ProfiledM a) = ProfiledM $ local f a
  reader = lift . reader

instance (ReflexHost t) => ReflexHost (ProfiledTimeline t) where
  type EventTrigger (ProfiledTimeline t) = EventTrigger t
  type EventHandle (ProfiledTimeline t) = EventHandle t
  type HostFrame (ProfiledTimeline t) = ProfiledM (HostFrame t)

instance MonadSubscribeEvent t m => MonadSubscribeEvent (ProfiledTimeline t) (ProfiledM m) where
  subscribeEvent = lift . subscribeEvent . coerce

instance PrimMonad m => PrimMonad (ProfiledM m) where
  type PrimState (ProfiledM m) = PrimState m
  primitive = lift . primitive

instance MonadReflexHost t m => MonadReflexHost (ProfiledTimeline t) (ProfiledM m) where
  type ReadPhase (ProfiledM m) = ProfiledM (ReadPhase m)
  fireEventsAndRead ts r = lift $ fireEventsAndRead ts $ coerce r
  runHostFrame = lift . runHostFrame . coerce

instance MonadReadEvent t m => MonadReadEvent (ProfiledTimeline t) (ProfiledM m) where
  readEvent = lift . fmap coerce . readEvent
