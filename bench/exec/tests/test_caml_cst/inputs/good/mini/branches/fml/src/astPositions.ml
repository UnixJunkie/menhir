(* $Id$ *)

open Sig
open Positions
open MiniEst
open MiniAst

let position = function
  | EAssertFalse p -> p
  | EForall (p, _, _) -> p
  | EExists (p, _, _) -> p
  | EVar (p, _) -> p
  | EDCon (p, _) -> p
  | ELambda (p, _, _) -> p
  | EAppAnnoted (p, _, _, _) -> p
  | EMatchAnnoted (p, _, _, _) -> p
  | EBinding (p, _, _) -> p
  | ETypeConstraint (p, _, _) -> p
  | EImpredicativity (p, _, _, _, _) -> p
  | ERecordEmpty p -> p
  | ERecordAccess (p, _, _) -> p
  | ERecordExtend (p, _, _) -> p
  | ERecordUpdate (p, _, _, _) -> p
  | EPrimApp (p, _, _) -> p
  | EError _ -> assert false

let joine = joinf position

let lposition = ljoinf position

let bposition = function
  | BindValue (p, _) -> p
  | BindRecValue (p, _) -> p
  | TypeDec (p, _) -> p

let bjoin = joinf bposition

let blposition = ljoinf bposition

let vposition = function
  | (p, _, _, _) -> p

let vlposition p = ljoinf vposition p

let tdposition = function
  | (p, _, _, _) -> p

let tdlposition p = ljoinf tdposition p

let pposition = function
  | PVar (p, _) -> p
  | PWildcard p -> p
  | PAlias (p, _, _) -> p
  | PTypeConstraint (p, _, _) -> p
  | PData (p, _, _, _) -> p
  | POr (p, _) -> p
  | PAnd (p, _) -> p
  | PPrimitive (p, _) -> p
  | PZero p -> p

let pjoin = joinf pposition

let plposition = ljoinf pposition

