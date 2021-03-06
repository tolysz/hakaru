{-# LANGUAGE DataKinds
           , GADTs
           , Rank2Types
           , FlexibleContexts
           #-}

----------------------------------------------------------------
--                                                    2016.07.19
-- |
-- Module      :  Language.Hakaru.Evaluation.Coalesce
-- Copyright   :  Copyright (c) 2016 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  zsulliva@indiana.edu
-- Stability   :  experimental
-- Portability :  GHC-only
--
----------------------------------------------------------------

module Language.Hakaru.Evaluation.Coalesce
  ( coalesce )
  where

import qualified Language.Hakaru.Parser.AST as U
import           Language.Hakaru.Syntax.ABT
import qualified Data.Foldable              as F

import Language.Hakaru.Syntax.IClasses

coalesce
    :: U.AST
    -> U.AST
coalesce =
    cataABT_ alg
    where
    alg :: forall abt a. (ABT U.Term abt) => U.Term abt a -> abt '[] a
    alg (U.NaryOp_ op args) = syn $ U.NaryOp_ op (coalesceNaryOp op args)
    alg t                   = syn t

coalesceNaryOp
    :: (ABT U.Term abt)
    => U.NaryOp
    -> [abt '[] a]
    -> [abt '[] a]
coalesceNaryOp op = F.concatMap $ \ast' ->
     caseVarSyn ast' (return . var) $ \t ->
       case t of
       U.NaryOp_ op' args' | op == op' -> coalesceNaryOp op args'
       _                               -> [ast']


type M  = MetaABT U.SourceSpan U.Term

preserveMetadata
   :: (M xs a -> M xs a)
   -> M xs a
   -> M xs a
preserveMetadata f x =
    case getMetadata x of
      Nothing -> f x
      Just s  -> withMetadata s (f x)

cataABT_
    :: (forall    a. U.Term M a -> M '[] a)
    -> (forall xs a. M xs a     -> M xs  a)
cataABT_ syn_ = start
    where
    start :: forall xs a. M xs a -> M xs a
    start = preserveMetadata (loop . viewABT)

    loop ::  forall xs a. View (U.Term M) xs a -> M xs a
    loop (Syn  t)   = syn_  (fmap21 start t)
    loop (Var  x)   = var  x
    loop (Bind x e) = bind x (loop e)
