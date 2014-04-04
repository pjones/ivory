{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

--
-- QuasiQuoter for Ivory statements.
--
-- Copyright (C) 2014, Galois, Inc.
-- All rights reserved.
--

module Ivory.Language.CSyntax.QQ.StmtQQ where

import           Prelude hiding (exp, init)
import qualified Prelude as P

import Ivory.Language.CSyntax.QQ.ExprQQ
import Ivory.Language.CSyntax.QQ.Types

import           Language.Haskell.TH       hiding (Stmt, Exp, Type)
import qualified Language.Haskell.TH as T

import Language.Haskell.Meta.Parse (parseExp)

import qualified Ivory.Language as I

import           Data.List (nub)
import           Control.Monad (forM_)
import           MonadLib   (set, get)
import qualified MonadLib   as M
import           Data.Monoid
import qualified Data.DList as D

import Ivory.Language.CSyntax.ParseAST

--------------------------------------------------------------------------------
-- Monad for inserting statements.  Necessary since we'll parse dereferences as
-- expressions but they become Ivory/Haskell statements.

newtype StmtM a b = StmtM
  { unStmtM :: M.StateT (D.DList a) T.Q b
  } deriving (Functor, Monad)

instance M.StateM (StmtM a) (D.DList a) where
  get = StmtM M.get
  set = StmtM . M.set

insert :: a -> StmtM a ()
insert a = do
  st <- get
  set (D.snoc st a)

runToQ :: StmtM a b -> Q (b, D.DList a)
runToQ m = M.runStateT mempty (unStmtM m)

liftQ :: Q b -> StmtM a b
liftQ = StmtM . M.lift

type TStmtM a = StmtM T.Stmt a

runToStmts :: TStmtM a -> Q [T.Stmt]
runToStmts m = do
  (_, st) <- runToQ m
  return (D.toList st)

--------------------------------------------------------------------------------

fromProgram :: [Stmt] -> Q T.Exp
fromProgram program = return .
  DoE =<< (runToStmts $ forM_ program fromStmt)

fromBlock :: [Stmt] -> TStmtM T.Exp
fromBlock = liftQ . fromProgram

fromStmt :: Stmt -> TStmtM ()
fromStmt stmt = case stmt of
  IfTE cond blk0 blk1
    -> do
    cd <- fromExp cond
    b0 <- fromBlock blk0
    b1 <- fromBlock blk1
    insert $ NoBindS (AppE (AppE (AppE (VarE 'I.ifte_) cd) b0) b1)
  Assert exp
    -> do
    e <- fromExp exp
    insert $ NoBindS (AppE (VarE 'I.assert) e)
  Assume exp
    -> do
    e <- fromExp exp
    insert $ NoBindS (AppE (VarE 'I.assume) e)
  Return exp
    -> do
    e <- fromExp exp
    insert $ NoBindS (AppE (VarE 'I.ret) e)
  ReturnVoid
    -> insert $ NoBindS (VarE 'I.retVoid)
  Store ptr exp
    -> do
      e <- fromExp exp
      let storeIt p = insert $ NoBindS (AppE (AppE (VarE 'I.store) p) e)
      case ptr of
        RefVar ref      ->    -- ref
          storeIt (iVar ref)
        ArrIx ref ixExp -> do -- (arr ! ix)
          ix <- fromExp ixExp
          let p' = InfixE (Just $ iVar ref) (VarE '(I.!)) (Just ix)
          storeIt p'
  Assign var exp
    -> do
    e <- fromExp exp
    let v = mkName var
    insert $ BindS (VarP v) (AppE (VarE 'I.assign) e)
  Call mres sym exps
    -> do
    es <- mapM fromExp exps
    let func f   = AppE (VarE f) (VarE $ mkName sym)
    let callit f = foldl AppE (func f) es
    insert $ case mres of
      Nothing  -> NoBindS (callit 'I.call_)
      Just res -> let r = mkName res in
                  BindS (VarP r) (callit 'I.call)
  RefCopy refDest refSrc
    -> do
    eDest <- fromExp refDest
    eSrc  <- fromExp refSrc
    insert $ NoBindS (AppE (AppE (VarE 'I.refCopy) eDest) eSrc)
  Forever blk
    -> do
    b <- fromBlock blk
    insert $ NoBindS (AppE (VarE 'I.forever) b)
--  Break -> insert $ NoBindS (VarE 'I.break)
  AllocRef alloc
    -> fromAlloc alloc
  Loop ixVar blk
    -> do
    b <- fromBlock blk
    insert $ NoBindS (AppE (VarE 'I.arrayMap) (LamE [VarP (mkName ixVar)] b))

--------------------------------------------------------------------------------
-- Initializers

fromAlloc :: AllocRef -> TStmtM ()
fromAlloc alloc = case alloc of
  AllocBase ref exp
    -> do e <- fromExp exp
          let p = mkName ref
          insert $ BindS (VarP p)
                         (AppE (VarE 'I.local) (AppE (VarE 'I.ival) e))
  AllocArr arr exps
    -> do es <- mapM fromExp exps
          let mkIval = AppE (VarE 'I.ival)
          let init = ListE (map mkIval es)
          let p = mkName arr
          insert $ BindS (VarP p)
                         (AppE (VarE 'I.local) (AppE (VarE 'I.iarray) init))

-----------------------------------------
-- Insert dereference statements

-- Collect up dereference expressions, which turn into Ivory statements.  We
-- only need one dereference statement for each unique dereferenced equation.
fromExp :: Exp -> TStmtM T.Exp
fromExp exp = do
  env <- mkDerefStmts exp
  return (toExp env exp)

mkDerefStmts :: Exp -> TStmtM DerefVarEnv
mkDerefStmts exp = do
  envs <- mapM insertDerefStmt (collectRefExps exp)
  return (concat envs)

-- For each unique expression that requires a dereference, insert a dereference
-- statement.
insertDerefStmt :: DerefExp -> TStmtM DerefVarEnv
insertDerefStmt dv = case dv of
  RefExp var    -> do
    nm <- liftQ (newName var)
    insert $ BindS (VarP nm) (AppE (VarE 'I.deref) (nmVar var))
    return [(dv, nm)]
  ArrIxExp arr ixExp -> do
    env <- mkDerefStmts ixExp
    let e = toExp env ixExp
    nm <- liftQ (newName arr)
    let arrIx = InfixE (Just (nmVar arr)) (VarE '(I.!)) (Just e)
    insert $ BindS (VarP nm) (AppE (VarE 'I.deref) arrIx)
    return ((dv, nm) : env)
  where
  nmVar = VarE . mkName

collectRefExps :: Exp -> [DerefExp]
collectRefExps exp = nub $ case exp of
  ExpLit _           -> []
  ExpVar _           -> []
  ExpDeref refVar    -> [RefExp refVar]
  ExpOp _ args       -> concatMap collectRefExps args
  -- ix is an expression that is processed when the statement is inserted.
  ExpArrIx arr ix    -> [ArrIxExp arr ix]
  ExpAnti _          -> []

--------------------------------------------------------------------------------
-- Helpers

-- | Parse a Ivory variable.
iVar :: String -> T.Exp
iVar str = case parseExp str of
  Left err -> error err
  Right e  -> e

