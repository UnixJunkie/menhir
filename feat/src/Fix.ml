(* The library fix has been renamed vendored_fix so as to prevent Dune
   from complaining about a conflict with a copy of fix that might be
   installed on the user's system. *)

(* As a result, the library is now accessible under the name Vendored_fix.
   Because we do not want to pollute our sources with this name, we define the
   module Fix as an alias for Vendored_fix. *)

include Vendored_fix
