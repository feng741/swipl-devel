/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2011, VU University Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

:- module(predicate_options,
	  [ predicate_options/3,		% +PI, +Arg, +Options
	    current_predicate_option/3,		% ?PI, ?Arg, ?Option
	    current_option_arg/2,		% ?PI, ?Arg
						% Create declarations
	    current_predicate_options/3,	% ?PI, ?Arg, ?Options
	    assert_predicate_options/4,		% +PI, +Arg, +Options, ?New
	    retractall_predicate_options/0,
	    derived_predicate_options/3,	% :PI, ?Arg, ?Options
	    derived_predicate_options/1,	% +Module
						% Checking
	    check_predicate_options/0,
	    derive_predicate_options/0,
	    check_predicate_options/1		% :PredicateIndicator
	  ]).
:- use_module(library(lists)).
:- use_module(library(pairs)).
:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(library(debug)).
:- use_module(library(prolog_clause)).
:- use_module(library(prolog_xref)).

:- meta_predicate
	predicate_options(:, +, +),
	assert_predicate_options(:, +, +, ?),
	current_predicate_option(:, ?, ?),
	current_predicate_options(:, ?, ?),
	current_option_arg(:, ?),
	pred_option(:,-),
	derived_predicate_options(:,?,?),
	check_predicate_options(:).

/** <module> Access and analyse predicate options

This  module  provides  the  developers   interface  for  the  directive
predicate_options/3. This directive allows  us   to  specify  that e.g.,
open/4 processes options using the 4th  argument and supports the option
=type= using the values =text= and  =binary=. Declaring options that are
processed allows for more reliable  handling   of  predicate options and
simplifies porting applications. This  libarry   provides  the following
functionality:

  * Query supported options through current_predicate_option/3
    or current_predicate_options/3.  This is intended to support
    conditional compilation and an IDE.
  * Derive additional declarations through dataflow analysis using
    derive_predicate_options/0.
  * Perform a compile-time analysis of the entire loaded program using
    check_predicate_options/0.

Below, we describe some use-cases.

  $ Quick check of a program :
  This scenario is useful as an occasional check or to assess problems
  with option-handling for porting an application to SWI-Prolog.  It
  consists of three steps: loading the program (1 and 2), deriving
  option handling for application predicates (3) and running the
  checker (4).

    ==
    1 ?- [load].
    2 ?- autoload.
    3 ?- derive_predicate_options.
    4 ?- check_predicate_options.
    ==

  $ Add declaations to your program :
  Adding declarations about option processes improves the quality of
  the checking.  The analysis of derive_predicate_options/0 may miss
  options and does not derive the types for options that are processed
  in Prolog code.  The process is similar to the above.  In steps 4 and
  further, the inferred declarations are listed, inspected and added to
  the source-code of the module.

    ==
    1 ?- [load].
    2 ?- autoload.
    3 ?- derive_predicate_options.
    4 ?- derived_predicate_options(module_1).
    5 ?- derived_predicate_options(module_2).
    6 ?- ...
    ==

  $ Declare option processing requirements :
  If an application requires that open/4 needs to support lock(write),
  it may do so using the derective below.  This directive raises an
  exception when loaded on a Prolog implementation that does not support
  this option.

    ==
    :- current_predicate_option(open/4, 4, lock(write)).
    ==

@see library(option) for accessing options in Prolog code.
*/

:- multifile option_decl/3.
:- dynamic   dyn_option_decl/3.

%%	predicate_options(:PI, +Arg, +Options) is det.
%
%	Declare that the predicate PI processes options on Arg.  Options
%	is a list of options processed.  Each element is one of:
%
%	  * Option(ModeAndType)
%	  PI processes Option. The option-value must comply to
%	  ModeAndType.  Mode is one of + or - and Type is a type as
%	  accepted by must_be/2.
%
%	  * pass_to(:PI,Arg)
%	  Options are passed to the indicated predicate.
%
%	This predicate is normally used as a directive, in which case it
%	is processed by expand_term/2. If  predicate_options/3 is called
%	as a predicate, the information is asserted into the database.

predicate_options(PI, Arg, Options) :-
	throw(error(context_error(nodirective,
				  predicate_options(PI, Arg, Options)), _)).


%%	assert_predicate_options(:PI, +Arg, +Options, ?New) is semidet.
%
%	As predicate_options(:PI, +Arg, +Options).  New   is  a  boolean
%	indicating whether the declarations  have   changed.  If  new is
%	provided and =false=, the predicate   becomes  semidet and fails
%	without modifications if modifications are required.

assert_predicate_options(PI, Arg, Options, New) :-
	canonical_pi(PI, M:Name/Arity),
	functor(Head, Name, Arity),
	(   dyn_option_decl(Head, M, Arg)
	->  true
	;   New = true,
	    assertz(dyn_option_decl(Head, M, Arg))
	),
	phrase('$predopts':option_clauses(Options, Head, M, Arg),
	       OptionClauses),
	forall(member(Clause, OptionClauses),
	       assert_option_clause(Clause, New)),
	(   var(New)
	->  New = false
	;   true
	).

assert_option_clause(Clause, New) :-
	rename_clause(Clause, NewClause,
		      '$pred_option'(A,B,C,D), '$dyn_pred_option'(A,B,C,D)),
	clause_head(NewClause, NewHead),
	(   clause(NewHead, _)
	->  true
	;   New = true,
	    assertz(NewClause)
	).

clause_head(M:(Head:-_Body), M:Head) :- !.
clause_head((M:Head :-_Body), M:Head) :- !.
clause_head(Head, Head).

rename_clause(M:Clause, M:NewClause, Head, NewHead) :- !,
	rename_clause(Clause, NewClause, Head, NewHead).
rename_clause((Head :- Body), (NewHead :- Body), Head, NewHead) :- !.
rename_clause(Head, NewHead, Head, NewHead) :- !.
rename_clause(Head, Head, _, _).



		 /*******************************
		 *	  QUERY OPTIONS		*
		 *******************************/

%%	current_option_arg(:PI, ?Arg) is nondet.
%
%	True when Arg of PI processes options

current_option_arg(Module:Name/Arity, Arg) :-
	current_option_arg(Module:Name/Arity, Arg, _DefM).

current_option_arg(Module:Name/Arity, Arg, DefM) :-
	atom(Name), integer(Arity), !,
	resolve_module(Module:Name/Arity, DefM:Name/Arity),
	functor(Head, Name, Arity),
	(   option_decl(Head, DefM, Arg)
	;   dyn_option_decl(Head, DefM, Arg)
	).
current_option_arg(M:Name/Arity, Arg, M) :-
	(   option_decl(Head, M, Arg)
	;   dyn_option_decl(Head, M, Arg)
	),
	functor(Head, Name, Arity).

%%	current_predicate_option(:PI, ?Arg, ?Option) is nondet.
%
%	True when Arg of PI processes Option.

current_predicate_option(Module:PI, Arg, Option) :-
	current_option_arg(Module:PI, Arg, DefM),
	PI = Name/Arity,
	functor(Head, Name, Arity),
	arg(Arg, Head, A),
	pred_option(DefM:Head, Option),
	arg(1, Option, A).

pred_option(M:Head, Option) :-
	pred_option(M:Head, Option, []).

pred_option(M:Head, Option, Seen) :-
	(   has_static_option_decl(M),
	    M:'$pred_option'(Head, _, Option, Seen)
	;   has_dynamic_option_decl(M),
	    M:'$dyn_pred_option'(Head, _, Option, Seen)
	).

has_static_option_decl(M) :-
	'$c_current_predicate'(_, M:'$pred_option'(_,_,_,_)).
has_dynamic_option_decl(M) :-
	'$c_current_predicate'(_, M:'$dyn_pred_option'(_,_,_,_)).



		 /*******************************
		 *	      TYPES		*
		 *******************************/

add_attr(Var, Value) :-
	(   get_attr(Var, predicate_options, Old)
	->  put_attr(Var, predicate_options, [Value|Old])
	;   put_attr(Var, predicate_options, [Value])
	).

system:predicate_option_type(Type, Arg) :-
	var(Arg), !,
	add_attr(Arg, option_type(Type)).
system:predicate_option_type(Type, Arg) :-
	must_be(Type, Arg).


system:predicate_option_mode(Mode, Arg) :-
	var(Arg), !,
	add_attr(Arg, option_mode(Mode)).
system:predicate_option_mode(Mode, Arg) :-
	check_mode(Mode, Arg).

check_mode(input, Arg) :-
	(   nonvar(Arg)
	->  true
	;   instantiation_error(Arg)
	).
check_mode(output, Arg) :-
	(   var(Arg)
	->  true
	;   instantiation_error(Arg)	% TBD: Uninstantiated
	).

attr_unify_hook([], _).
attr_unify_hook([H|T], Var) :-
	option_hook(H, Var),
	attr_unify_hook(T, Var).

option_hook(option_type(Type), Value) :-
	is_of_type(Type, Value).
option_hook(option_mode(Mode), Value) :-
	check_mode(Mode, Value).


attribute_goals(Var) -->
	{ get_attr(Var, predicate_options, Attrs) },
	option_goals(Attrs, Var).

option_goals([], _) --> [].
option_goals([H|T], Var) -->
	option_goal(H, Var),
	option_goals(T, Var).

option_goal(option_type(Type), Var) --> [predicate_option_type(Type, Var)].
option_goal(option_mode(Mode), Var) --> [predicate_option_mode(Mode, Var)].


		 /*******************************
		 *	OUTPUT DECLARATIONS	*
		 *******************************/

%%	current_predicate_options(:PI, ?Arg, ?Options) is nondet.
%
%	True when Options is the current   active option declaration for
%	PI  on  Arg.   See   predicate_options/3    for   the   argument
%	descriptions. If PI  is  ground  and   refers  to  an  undefined
%	predicate, the autoloader is used to  obtain a definition of the
%	predicate.

current_predicate_options(PI, Arg, Options) :-
	define_predicate(PI),
	setof(Arg-Option,
	      current_predicate_option_decl(PI, Arg, Option),
	      Options0),
	group_pairs_by_key(Options0, Grouped),
	member(Arg-Options, Grouped).

current_predicate_option_decl(PI, Arg, Option) :-
	current_predicate_option(PI, Arg, Option0),
	Option0 =.. [Name,Value],
	copy_term(Value,_,Goals),
	(   memberchk(predicate_option_mode(output, _), Goals)
	->  ModeAndType = -(Type)
	;   ModeAndType = Type
	),
	(   memberchk(predicate_option_type(Type, _), Goals)
	->  true
	;   Type = any
	),
	Option =.. [Name,ModeAndType].

define_predicate(PI) :-
	ground(PI), !,
	PI = M:Name/Arity,
	functor(Head, Name, Arity),
	once(predicate_property(M:Head, _)).
define_predicate(_).

%%	derived_predicate_options(:PI, ?Arg, ?Options) is nondet.
%
%	True  when  Options  is  the  current  _derived_  active  option
%	declaration for PI on Arg.

derived_predicate_options(PI, Arg, Options) :-
	define_predicate(PI),
	setof(Arg-Option,
	      derived_predicate_option(PI, Arg, Option),
	      Options0),
	group_pairs_by_key(Options0, Grouped),
	member(Arg-Options1, Grouped),
	PI = M:_,
	phrase(expand_pass_to_options(Options1, M), Options2),
	sort(Options2, Options).

derived_predicate_option(PI, Arg, Decl) :-
	current_option_arg(PI, Arg, DefM),
	PI = _:Name/Arity,
	functor(Head, Name, Arity),
	has_dynamic_option_decl(DefM),
	(   has_static_option_decl(DefM),
	    DefM:'$pred_option'(Head, Decl, _, [])
	;   DefM:'$dyn_pred_option'(Head, Decl, _, [])
	).

%%	expand_pass_to_options(+OptionsIn, +Module, -OptionsOut)// is det.
%
%	Expand the options of pass_to(PI,Arg) if PI  does not refer to a
%	public predicate.

expand_pass_to_options([], _) --> [].
expand_pass_to_options([H|T], M) -->
	expand_pass_to(H, M),
	expand_pass_to_options(T, M).

expand_pass_to(pass_to(PI, Arg), Module) -->
	{ strip_module(Module:PI, M, Name/Arity),
	  functor(Head, Name, Arity),
	  \+ (   predicate_property(M:Head, exported)
	     ;   predicate_property(M:Head, public)
	     ;   M == system
	     ), !,
	  current_predicate_options(M:Name/Arity, Arg, Options)
	},
	list(Options).
expand_pass_to(Option, _) -->
	[Option].

list([]) --> [].
list([H|T]) --> [H], list(T).

%%	derived_predicate_options(+Module) is det.
%
%	Derive predicate option declarations for   the  given module and
%	print them to the current output.

derived_predicate_options(Module) :-
	findall(predicate_options(Module:PI, Arg, Options),
		( derived_predicate_options(Module:PI, Arg, Options),
		  PI = Name/Arity,
		  functor(Head, Name, Arity),
		  (   predicate_property(Module:Head, exported)
		  ->  true
		  ;   predicate_property(Module:Head, public)
		  )
		),
		Decls0),
	maplist(qualify_decl(Module), Decls0, Decls1),
	sort(Decls1, Decls),
	forall(member(Decl, Decls),
	       portray_clause((:-Decl))).

qualify_decl(M,
	     predicate_options(PI0, Arg, Options0),
	     predicate_options(PI1, Arg, Options1)) :-
	qualify(PI0, M, PI1),
	maplist(qualify_option(M), Options0, Options1).

qualify_option(M, pass_to(PI0, Arg), pass_to(PI1, Arg)) :- !,
	qualify(PI0, M, PI1).
qualify_option(_, Opt, Opt).

qualify(M:Term, M, Term) :- !.
qualify(QTerm, _, QTerm).


		 /*******************************
		 *	      CLEANUP		*
		 *******************************/

%%	retractall_predicate_options is det.
%
%	Remove all dynamically (derived) predicate options.

retractall_predicate_options :-
	forall(retract(dyn_option_decl(_,M,_)),
	       abolish(M:'$dyn_pred_option'/4)).


		 /*******************************
		 *     COMPILE-TIME CHECKER	*
		 *******************************/


:- thread_local
	new_decl/1.

%%	check_predicate_options is det.
%
%	Analyse loaded program for  errornous   options.  This predicate
%	decompiles  the  current  program  and  searches  for  calls  to
%	predicates that process  options.  For   each  option  list,  it
%	validates  whether  the  provided  options   are  supported  and
%	validates the argument type.  This   predicate  performs partial
%	dataflow analysis to track option-lists inside a clause.
%
%	@see	derive_predicate_options/0 can be used to derive
%		declarations for predicates that pass options. This
%		predicate should normally be called before
%		check_predicate_options/0.

check_predicate_options :-
	forall(current_module(Module),
	       check_predicate_options_module(Module)).

%%	derive_predicate_options is det.
%
%	Derive  new  predicate  option    declarations.  This  predicate
%	analyses the loaded program to find clauses that process options
%	using one of  the  predicates   from  library(option)  or passes
%	options to other predicates that are   known to process options.
%	The process is repeated until no new declarations are retrieved.
%
%	@see autoload/0 may be used to complete the loaded program.

derive_predicate_options :-
	derive_predicate_options(NewDecls),
	(   NewDecls == []
	->  true
	;   print_message(informational, check_options(new(NewDecls))),
	    new_decls(NewDecls),
	    derive_predicate_options
	).

new_decls([]).
new_decls([predicate_options(PI, A, O)|T]) :-
	assert_predicate_options(PI, A, O, _),
	new_decls(T).


derive_predicate_options(NewDecls) :-
	call_cleanup(
	    ( forall(
		  current_module(Module),
		  forall(
		      ( predicate_in_module(Module, PI),
			PI = Name/Arity,
			functor(Head, Name, Arity),
			catch(Module:clause(Head, Body, Ref), _, fail)
		      ),
		      check_clause((Head:-Body), Module, Ref, decl))),
	      (	  setof(Decl, retract(new_decl(Decl)), NewDecls)
	      ->  true
	      ;	  NewDecls = []
	      )
	    ),
	    retractall(new_decl(_))).


check_predicate_options_module(Module) :-
	forall(predicate_in_module(Module, PI),
	       check_predicate_options(Module:PI)).

predicate_in_module(Module, PI) :-
	current_predicate(Module:PI),
	PI = Name/Arity,
	functor(Head, Name, Arity),
	\+ predicate_property(Module:Head, imported_from(_)).

%%	check_predicate_options(:PredicateIndicator) is det.
%
%	Verify calls to predicates that have   options in all clauses of
%	the predicate indicated by PredicateIndicator.

check_predicate_options(Module:Name/Arity) :-
	debug(predicate_options, 'Checking ~q', [Module:Name/Arity]),
	functor(Head, Name, Arity),
	forall(catch(Module:clause(Head, Body, Ref), _, fail),
	       check_clause((Head:-Body), Module, Ref, check)).

%%	check_clause(+Clause, +Module, +Ref, +Action) is det.
%
%	Action is one of
%
%	  * decl
%	  Create additional declarations
%	  * check
%	  Produce error messages

check_clause((Head:-Body), M, ClauseRef, Action) :- !,
	catch(check_body(Body, M, _, Action), E, true),
	(   var(E)
	->  option_decl(M:Head, Action)
	;   (   clause_info(ClauseRef, File, TermPos, _NameOffset),
	        TermPos = term_position(_,_,_,_,[_,BodyPos]),
	        catch(check_body(Body, M, BodyPos, Action),
		      error(Formal, ArgPos), true),
		compound(ArgPos),
		arg(1, ArgPos, CharPos),
		integer(CharPos)
	    ->	Location = filepos(File, CharPos)
	    ;   Location = clause(ClauseRef),
		E = error(Formal, _)
	    ),
	    print_message(error, predicate_option_error(Formal, Location))
	).


%%	check_body(+Body, +Module, +TermPos, +Action)

check_body(Var, _, _, _) :-
	var(Var), !.
check_body(M:G, _, term_position(_,_,_,_,[_,Pos]), Action) :- !,
	check_body(G, M, Pos, Action).
check_body((A,B), M, term_position(_,_,_,_,[PA,PB]), Action) :- !,
	check_body(A, M, PA, Action),
	check_body(B, M, PB, Action).
check_body(A=B, _, _, _) :-		% partial evaluation
	A=B, !.
check_body(Goal, M, term_position(_,_,_,_,ArgPosList), Action) :-
	callable(Goal),
	functor(Goal, Name, Arity),
	(   '$get_predicate_attribute'(M:Goal, imported, DefM)
	->  true
	;   DefM = M
	),
	(   eval_option_pred(DefM:Goal)
	->  true
	;   current_option_arg(DefM:Name/Arity, OptArg), !,
	    arg(OptArg, Goal, Options),
	    nth1(OptArg, ArgPosList, ArgPos),
	    check_options(DefM:Name/Arity, OptArg, Options, ArgPos, Action)
	).
check_body(Goal, M, _, Action) :-
	prolog_xref:called_by(Goal, Called),
	Called \== [], !,
	check_xref_called(Called, M, Action).
check_body(Meta, M, term_position(_,_,_,_,ArgPosList), Action) :-
	'$get_predicate_attribute'(M:Meta, meta_predicate, Head), !,
	check_meta_args(1, Head, Meta, M, ArgPosList, Action).
check_body(_, _, _, _).

check_meta_args(I, Head, Meta, M, [ArgPos|ArgPosList], Action) :-
	arg(I, Head, AS), !,
	(   AS == 0
	->  arg(I, Meta, MA),
	    check_body(MA, M, ArgPos, Action)
	;   true
	),
	succ(I, I2),
	check_meta_args(I2, Head, Meta, M, ArgPosList, Action).
check_meta_args(_,_,_,_, _, _).

%%	check_xref_called(+CalledBy, +M, +Action) is det.
%
%	Handle results from prolog:called_by/2.

check_xref_called([], _, _).
check_xref_called([H|T], M, Action) :-
	(   H = G+N
	->  (   extend(G, N, G2)
	    ->	check_body(G2, M, _, Action)
	    ;	true
	    )
	;   check_body(H, M, _, Action)
	),
	check_xref_called(T, M, Action).

extend(Goal, N, GoalEx) :-
	callable(Goal),
	Goal =.. List,
	length(Extra, N),
	append(List, Extra, ListEx),
	GoalEx =.. ListEx.


%%	check_options(:Predicate, +OptionArg, +Options, +ArgPos, +Action)
%
%	Verify the list Options,  that  is   passed  into  Predicate  on
%	argument OptionArg. ArgPos is a   term-position  term describing
%	the location of the Options list. If  Options is a partial list,
%	the tail is annotated with pass_to(PI, OptArg).

check_options(PI, OptArg, QOptions, ArgPos, Action) :-
	debug(predicate_options, '\tChecking call to ~q', [PI]),
	remove_qualifier(QOptions, Options),
	must_be(list_or_partial_list, Options),
	check_option_list(Options, PI, OptArg, Options, ArgPos, Action).

remove_qualifier(X, X) :-
	var(X), !.
remove_qualifier(_:X, X) :- !.
remove_qualifier(X, X).

check_option_list(Var,  PI, OptArg, _, _, _) :-
	var(Var), !,
	annotate(Var, pass_to(PI, OptArg)).
check_option_list([], _, _, _, _, _).
check_option_list([H|T], PI, OptArg, Options, ArgPos, Action) :-
	check_option(PI, OptArg, H, ArgPos, Action),
	check_option_list(T, PI, OptArg, Options, ArgPos, Action).

check_option(_, _, _, _, decl) :- !.
check_option(PI, OptArg, Opt, ArgPos, _) :-
	catch(current_predicate_option(PI, OptArg, Opt), E, true), !,
	(   var(E)
	->  true
	;   E = error(Formal,_),
	    throw(error(Formal,ArgPos))
	).
check_option(_PI, _OptArg, Opt, ArgPos, _) :-
	throw(error(existence_error(option, Opt), ArgPos)).


		 /*******************************
		 *	    ANNOTATIONS		*
		 *******************************/

%%	annotate(+Var, +Term) is det.
%
%	Use constraints to accumulate annotations   about  variables. If
%	two annotated variables are unified, the attributes are joined.

annotate(Var, Term) :-
	(   get_attr(Var, predopts_analysis, Old)
	->  put_attr(Var, predopts_analysis, [Term|Old])
	;   var(Var)
	->  put_attr(Var, predopts_analysis, [Term])
	;   true
	).

annotations(Var, Annotations) :-
	get_attr(Var, predopts_analysis, Annotations).

predopts_analysis:attr_unify_hook(Opts, Value) :-
	get_attr(Value, predopts_analysis, Others), !,
	append(Opts, Others, All),
	put_attr(Value, predopts_analysis, All).
predopts_analysis:attr_unify_hook(_, _).


		 /*******************************
		 *	   PARTIAL EVAL		*
		 *******************************/

eval_option_pred(swi_option:option(Opt, Options)) :-
	processes(Opt, Spec),
	annotate(Options, Spec).
eval_option_pred(swi_option:option(Opt, Options, _Default)) :-
	processes(Opt, Spec),
	annotate(Options, Spec).
eval_option_pred(swi_option:select_option(Opt, Options, Rest)) :-
	ignore(Rest = Options),
	processes(Opt, Spec),
	annotate(Options, Spec).
eval_option_pred(swi_option:select_option(Opt, Options, Rest, _Default)) :-
	ignore(Rest = Options),
	processes(Opt, Spec),
	annotate(Options, Spec).
eval_option_pred(swi_option:meta_options(_Cond, QOptionsIn, QOptionsOut)) :-
	remove_qualifier(QOptionsIn, OptionsIn),
	remove_qualifier(QOptionsOut, OptionsOut),
	ignore(OptionsIn = OptionsOut).

processes(Opt, Spec) :-
	compound(Opt),
	functor(Opt, OptName, 1),
	Spec =.. [OptName,any].


		 /*******************************
		 *	  NEW DECLARTIONS	*
		 *******************************/

%%	option_decl(:Head, +Action) is det.
%
%	Add new declarations based on attributes   left  by the analysis
%	pass. We do not add declarations   for system modules or modules
%	that already contain static declarations.
%
%	@tbd	Should we add a mode to include generating declarations
%		for system modules and modules with static declarations?

option_decl(_, check) :- !.
option_decl(M:_, _) :-
	system_module(M), !.
option_decl(M:_, _) :-
	has_static_option_decl(M), !.
option_decl(M:Head, _) :-
	arg(AP, Head, QA),
	remove_qualifier(QA, A),
	annotations(A, Annotations0),
	functor(Head, Name, Arity),
	PI = M:Name/Arity,
	delete(Annotations0, pass_to(PI,AP), Annotations),
	Annotations \== [],
	Decl = predicate_options(PI, AP, Annotations),
	(   new_decl(Decl)
	->  true
	;   assert_predicate_options(M:Name/Arity, AP, Annotations, false)
	->  true
	;   assertz(new_decl(Decl)),
	    debug(predicate_options(decl), '~q', [Decl])
	),
	fail.
option_decl(_, _).

system_module(system) :- !.
system_module(Module) :-
	sub_atom(Module, 0, _, _, $).


		 /*******************************
		 *	       MISC		*
		 *******************************/

canonical_pi(M:Name//Arity, M:Name/PArity) :-
	integer(Arity),
	PArity is Arity+2.
canonical_pi(PI, PI).

%%	resolve_module(:PI, -DefPI) is det.
%
%	Find the real predicate  indicator   pointing  to the definition
%	module of PI. This is similar to using predicate_property/3 with
%	the       property       imported_from,         but        using
%	'$get_predicate_attribute'/3    avoids    auto-importing     the
%	predicate.

resolve_module(Module:Name/Arity, DefM:Name/Arity) :-
	functor(Head, Name, Arity),
	(   '$get_predicate_attribute'(Module:Head, imported, M)
	->  DefM = M
	;   DefM = Module
	).


		 /*******************************
		 *	      MESSAGES		*
		 *******************************/
:- multifile
	prolog:message//1.

prolog:message(predicate_option_error(Formal, Location)) -->
	error_location(Location),
	'$messages':term_message(Formal). % TBD: clean interface
prolog:message(check_options(new(Decls))) -->
	[ 'Inferred declarations:'-[], nl ],
	new_decls(Decls).

error_location(filepos(File, CharPos)) -->
	{ filepos_line(File, CharPos, Line, LinePos) },
	[ '~w:~d:~d: '-[File, Line, LinePos] ].
error_location(clause(ClauseRef)) -->
	{ clause_property(ClauseRef, file(File)),
	  clause_property(ClauseRef, line_count(Line))
	}, !,
	[ '~w:~d: '-[File, Line] ].
error_location(clause(ClauseRef)) -->
	[ 'Clause ~q: '-[ClauseRef] ].

filepos_line(File, CharPos, Line, LinePos) :-
	setup_call_cleanup(
	    ( open(File, read, In),
	      open_null_stream(Out)
	    ),
	    ( Skip is CharPos-1,
	      copy_stream_data(In, Out, Skip),
	      stream_property(In, position(Pos)),
	      stream_position_data(line_count, Pos, Line),
	      stream_position_data(line_position, Pos, LinePos)
	    ),
	    ( close(Out),
	      close(In)
	    )).

new_decls([]) --> [].
new_decls([H|T]) -->
	[ '    :- ~q'-[H], nl ],
	new_decls(T).


		 /*******************************
		 *	SYSTEM DECLARATIONS	*
		 *******************************/

:- use_module(library(dialect/swi/syspred_options)).
