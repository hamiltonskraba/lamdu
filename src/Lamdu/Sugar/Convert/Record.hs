module Lamdu.Sugar.Convert.Record
    ( convertEmpty, convertExtend
    ) where

import           AST (Tree, Ann, ann)
import           AST.Term.Row (RowExtend(..))
import qualified Control.Lens as Lens
import qualified Data.Property as Property
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Sugar.Convert.Composite as Composite
import           Lamdu.Sugar.Convert.Expression.Actions (addActions)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Internal
import           Lamdu.Sugar.Types

import           Lamdu.Prelude

plValI :: Lens.Lens' (Input.Payload m a) (ExprIRef.ValI m)
plValI = Input.stored . Property.pVal

convertEmpty ::
    (Monad m, Monoid a) => Input.Payload m a -> ConvertM m (ExpressionU m a)
convertEmpty pl =
    Composite.convertEmpty DataOps.recExtend pl
    <&> BodyRecord
    >>= addActions [] pl

convertExtend ::
    (Monad m, Monoid a) =>
    Tree (RowExtend T.Tag V.Term V.Term) (Ann (Input.Payload m a)) ->
    Input.Payload m a ->
    ConvertM m (ExpressionU m a)
convertExtend (RowExtend tag val rest) exprPl =
    do
        valS <- ConvertM.convertSubexpression val
        restS <- ConvertM.convertSubexpression rest
        let recP =
                Composite.ExtendVal
                { Composite._extendTag = tag
                , Composite._extendValI = val ^. ann . plValI
                , Composite._extendRest = rest ^. ann
                }
        Composite.convert DataOps.recExtend V.LRecEmpty mkRecExtend _BodyRecord valS restS exprPl recP
    where
        mkRecExtend t v r = RowExtend t v r & V.BRecExtend
