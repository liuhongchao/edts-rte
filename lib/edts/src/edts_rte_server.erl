%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc
%%% This file is part of EDTS.
%%%
%%% EDTS is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU Lesser General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% EDTS is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU Lesser General Public License for more details.
%%%
%%% You should have received a copy of the GNU Lesser General Public License
%%% along with EDTS. If not, see <http://www.gnu.org/licenses/>.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =======================================================
-module(edts_rte_server).

-behaviour(gen_server).

%%%_* Exports =================================================================

%% server API
-export([start/0, stop/0, start_link/0]).

-export([started_p/0]).

%% Debugger API
-export([ rte_run/3
        , finished_attach/1
        , send_binding/1
        , send_exit/0
        , read_and_add_records/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%%_* Includes =================================================================
-include_lib("eunit/include/eunit.hrl").

%%%_* Defines ==================================================================
-define(SERVER, ?MODULE).
-define(RCDTBL, edts_rte_record_table).

-record(dbg_state, { proc         = unattached :: unattached | pid()
                   , bindings     = []         :: binding()
                   , mfa          = {}         :: {} | tuple()
                   , record_table = undefined
                   }).

%%%_* Types ====================================================================
-type state()   :: #dbg_state{}.
-type binding() :: [{atom(), any()}].

%%%_* API ======================================================================
start() ->
  ?MODULE:start_link(),
  {node(), ok}.

stop() ->
  ok.

started_p() -> whereis(?SERVER) =/= undefined.

%%------------------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
%%-----------------------------------------------------------------------------
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%------------------------------------------------------------------------------
%% @doc
%% Run function
%% @end
-spec rte_run(Module::module(), Fun::function(), Args::list()) -> any().
%%------------------------------------------------------------------------------
rte_run(Module, Fun, Args) ->
  gen_server:call(?SERVER, {rte_run, Module, Fun, Args}).

finished_attach(Pid) ->
  gen_server:cast(?SERVER, {finished_attach, Pid}).

send_binding(Msg) ->
  gen_server:cast(?SERVER, {send_binding, Msg}).

send_exit() ->
  gen_server:cast(?SERVER, exit).

%% FIXME: need to come up with a way to add all existing records from
%%        a project and remove records when recompile a particular module
read_and_add_records(Module) ->
  edts_rte_record_manager:read_and_add_records(Module, ?RCDTBL).

%%%_* gen_server callbacks  ====================================================
%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
-spec init(list()) -> {ok, state()} |
                      {ok, state(), timeout()} |
                      ignore |
                      {stop, atom()}.
%%------------------------------------------------------------------------------
init([]) ->
  %% set the table to public to make debugging easier
  RcdTbl = ets:new(?RCDTBL, [public, named_table]),
  io:format("RcdTbl:~p", [RcdTbl]),
  {ok, #dbg_state{record_table = RcdTbl}}.

handle_call({rte_run, Module, Fun, Args}, _From, State) ->
  RcdTbl   = State#dbg_state.record_table,
  %% try to read the record from this module.. right now this is the
  %% only record support
  AddedRds = edts_rte_record_manager:read_and_add_records(Module, RcdTbl),
  io:format("AddedRds:~p~n", [AddedRds]),
  ArgsTerm = to_term(Args, RcdTbl),
  io:format("ArgsTerm:~p~n", [ArgsTerm]),
  ok       = edts_rett_server:set_rte_flag(),
  [Module] = edts_rett_server:interpret_modules([Module]),
  Arity    = length(ArgsTerm),
  io:format("Arity:~p~n", [Arity]),
  io:format("get function body after interpret~n"),
  {ok, set, {Module, Fun, Arity}} =  edts_rett_server:set_breakpoint(Module, Fun, Arity),
  io:format("rte_run: after setbreakpoint~n"),
  Pid      = erlang:spawn(Module, Fun, ArgsTerm),
  io:format("called function pid:~p~n", [Pid]),
  {reply, {ok, finished}, State#dbg_state{ proc = Pid
                                         , bindings = []
                                         , mfa = {Module, Fun, Arity}}}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Handling all non call/cast messages
%% @end
%%
-spec handle_info(term(), state()) -> {noreply, state()} |
                                      {noreply, state(), Timeout::timeout()} |
                                      {stop, Reason::atom(), state()}.
handle_info(Msg, State) ->
  io:format("in handle_info ...., break_at, Msg:~p~n", [Msg]),
  {noreply, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
-spec handle_cast(Msg::term(), state()) -> {noreply, state()} |
                                           {noreply, state(), timeout()} |
                                           {stop, Reason::atom(), state()}.
%%------------------------------------------------------------------------------
handle_cast({finished_attach, Pid}, State) ->
  Pid = State#dbg_state.proc,
  edts_rett_server:step(),
  io:format("finish attach.....~n"),
  {noreply, State};

handle_cast({send_binding, {break_at, Bindings}}, State) ->
  io:format("send_binding......before step~n"),
  edts_rett_server:step(),
  io:format("send_binding......Bindings:~p~n",[Bindings]),
  {noreply, State#dbg_state{bindings = Bindings}};

handle_cast(exit, #dbg_state{bindings = Bindings} = State) ->
  %%io:format("in exit, Bindings:~p~n", [Bindings]),
  %% get function body
  {M, F, Arity}  = State#dbg_state.mfa,
  {ok, Body} = edts_code:get_function_body(M, F, Arity),
  io:format( "output FunBody, Bindings before replace:~p~n", [Body]),
  io:format( "Bindings:~n~p~n", [Bindings]),
  %% replace function body with bindings
  ReplacedFun = replace_var_with_val_in_fun(Body, Bindings),
  io:format( "output funbody after replacement:~p~n", [ReplacedFun]),
  send_fun(M, F, Arity, ReplacedFun),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

send_fun(M, F, Arity, FunBody) ->
  lists:foreach(fun(Fun) ->
                    Fun(M, F, Arity, FunBody)
                end, [ fun send_fun_to_edts/4
                     , fun send_fun_to_emacs/4
                     ]).

send_fun_to_emacs(M, F, Arity, FunBody) ->
  Id = lists:flatten(io_lib:format("*~p__~p__~p*", [M, F, Arity])),
  io:format("~n~nFunBody:~p~n", [FunBody]),
  Cmd = make_emacsclient_cmd(Id, FunBody),
  io:format("~n~ncmd:~p~n~n~n", [Cmd]),
  os:cmd(Cmd).

make_emacsclient_cmd(Id, FunBody) ->
  lists:flatten(io_lib:format(
                  "emacsclient -e '(edts-display-erl-fun-in-emacs "
                  ++ ""++"~p"++ " "
                  ++ " "++"~p"++" "
                  ++")'", [FunBody, Id])).

send_fun_to_edts(M, F, Arity, FunBody) ->
  Id  = lists:flatten(io_lib:format("~p__~p__~p", [M, F, Arity])),
  httpc:request(post, {url(), [], content_type(), mk_editor(Id, FunBody)}, [], []).

url() ->
  "http://localhost:4587/rte/editors/".

content_type() ->
  "application/json".

mk_editor(Id, FunBody) ->
  "{\"x\":74,\"y\":92,\"z\":1,\"id\":\""++Id++"\",\"code\":\""++FunBody++"\"}".

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
-spec terminate(Reason::atom(), _State :: state()) -> any().
%%------------------------------------------------------------------------------
terminate(_Reason, _State) ->
  ok.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
-spec code_change(OldVsn::string(), state(), Extra::term()) -> {ok, state()}.
%%------------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% @doc replace the temporary variables with the actual value in a function
-spec replace_var_with_val_in_fun( FunBody :: string()
                                 , Bindings :: binding()) -> string().
replace_var_with_val_in_fun(FunBody, Bindings) ->
  %% Parse function body to AbsForm
  {ok, FunBodyToken, _} = erl_scan:string(FunBody),
  {ok, AbsForm}         = erl_parse:parse_form(FunBodyToken),
  %% Replace variable names with variables' value and
  %% combine the Token to function string again
  NewFunBody            = do_replace_var_with_val_in_fun( AbsForm
                                                        , Bindings),
  io:format("New Body before flatten: ~p~n", [NewFunBody]),
  NewForm               = erl_pp:form(NewFunBody),
  lists:flatten(NewForm).

%% @doc replace variable names with values for a function
do_replace_var_with_val_in_fun( {function, L, FuncName, Arity, Clauses0}
                              , Bindings) ->
  Clauses = replace_var_with_val_in_clauses(Clauses0, Bindings),
  io:format("Replaced Clauses are:~p~n", [Clauses0]),
  {function, L, FuncName, Arity, Clauses}.

%% @doc replace variable names with values in each of the function clauses
replace_var_with_val_in_clauses([], _Bindings)                         ->
  [];
replace_var_with_val_in_clauses([ {clause,L,ArgList0,WhenList0,Lines0}|T]
                                , Bs)                                  ->
  %% replace variables' name with values in argument list
  ArgList  = replace_var_with_val_args(ArgList0, Bs),
  %% replace variables' name with values in "when" list
  WhenList = replace_var_with_val_args(WhenList0, Bs),
  %% replace variables' name with values for each of the expressions
  Lines    = replace_var_with_val_in_expr(Lines0, Bs),
  [ {clause,L,ArgList,WhenList,Lines}
  | replace_var_with_val_in_clauses(T, Bs)].

replace_var_with_val_args([], _Bindings)->[];
replace_var_with_val_args([VarExpr0|T], Bindings) ->
  VarExpr = replace_var_with_val(VarExpr0, Bindings),
  [VarExpr | replace_var_with_val_args(T, Bindings)].

replace_var_with_val_in_expr([], _Bindings)                               ->
  [];
replace_var_with_val_in_expr(Atom, _Bindings) when is_atom(Atom)          ->
  Atom;
replace_var_with_val_in_expr({nil, L}, _Bindings)                         ->
  {nil, L};
replace_var_with_val_in_expr({atom, _L, _A} = VarExpr, _Bindings)         ->
  VarExpr;
replace_var_with_val_in_expr({cons, L, Expr0, Rest0}, Bindings)           ->
  Expr = replace_var_with_val_in_expr(Expr0, Bindings),
  Rest = replace_var_with_val_in_expr(Rest0, Bindings),
  {cons, L, Expr, Rest};
replace_var_with_val_in_expr({tuple, L, Exprs0}, Bindings)                ->
  Exprs = lists:map(fun(Expr) ->
                        replace_var_with_val_in_expr(Expr, Bindings)
                    end, Exprs0),
  {tuple, L, Exprs};
replace_var_with_val_in_expr({float, _, _} = VarExpr, _Bindings)          ->
  VarExpr;
replace_var_with_val_in_expr({integer, _, _} = VarExpr, _Bindings)        ->
  VarExpr;
replace_var_with_val_in_expr({match,L,LExpr0,RExpr0}, Bindings)           ->
  LExpr = replace_var_with_val_in_expr(LExpr0, Bindings),
  RExpr = replace_var_with_val_in_expr(RExpr0, Bindings),
  {match,L,LExpr,RExpr};
replace_var_with_val_in_expr({var, _, _} = VarExpr, Bindings)             ->
  replace_var_with_val(VarExpr, Bindings);
replace_var_with_val_in_expr({op, _, _, _, _} = OpsExpr, Bindings)        ->
  replace_var_with_val_ops(OpsExpr, Bindings);
replace_var_with_val_in_expr({call, L, {atom, L, F0}, ArgList0}, Bindings)->
  F = replace_var_with_val_in_expr(F0, Bindings),
  {call, L, {atom, L, F}, replace_var_with_val_args(ArgList0, Bindings)};
replace_var_with_val_in_expr({call, L, {remote, L, M0, F0}, Args0}, Bindings) ->
  M = replace_var_with_val_in_expr(M0, Bindings),
  F = replace_var_with_val_in_expr(F0, Bindings),
  {call, L, {remote, L, M, F}, replace_var_with_val_args(Args0, Bindings)};
replace_var_with_val_in_expr({'case', L, CaseExpr0, Clauses0}, Bindings)  ->
  CaseExpr = replace_var_with_val_in_expr(CaseExpr0, Bindings),
  Clauses  = replace_var_with_val_in_clauses(Clauses0, Bindings),
  {'case', L, CaseExpr, Clauses};
replace_var_with_val_in_expr({string, _L, _Str} = String, _Bindings)      ->
  String;
replace_var_with_val_in_expr({'receive', L, Clauses0}, Bindings)        ->
  Clauses  = replace_var_with_val_in_clauses(Clauses0, Bindings),
  {'receive', L, Clauses};
replace_var_with_val_in_expr({'receive', L, Clauses0, Int, Exprs0}, Bindings)        ->
  Clauses  = replace_var_with_val_in_clauses(Clauses0, Bindings),
  Expr     = lists:map(fun (Expr) ->
                           replace_var_with_val_in_expr(Expr, Bindings)
                       end, Exprs0),
  {'receive', L, Clauses, Int, Expr};
replace_var_with_val_in_expr({record, _, _Name, _Fields} = Record, _Bindings)  ->
  edts_rte_record_manager:expand_records(?RCDTBL, Record);
replace_var_with_val_in_expr([Statement0|T], Bindings)                    ->
  Statement = replace_var_with_val_in_expr(Statement0, Bindings),
  [Statement | replace_var_with_val_in_expr(T, Bindings)].

replace_var_with_val_ops({op, L, Ops, LExpr0, RExpr0}, Bindings)  ->
  LExpr = replace_var_with_val_in_expr(LExpr0, Bindings),
  RExpr = replace_var_with_val_in_expr(RExpr0, Bindings),
  {op, L, Ops, LExpr, RExpr}.

replace_var_with_val({var, L, VariableName}, Bindings) ->
  Value = proplists:get_value(VariableName, Bindings),
  io:format("VarName:~p   L:~p    Val:~p~n", [VariableName, L, Value]),
  Val = do_replace(Value, L),
  io:format("replaced Var:~p~n", [Val]),
  Val;
replace_var_with_val(Other, _Bindings)                 ->
  Other.

do_replace(Value, L) ->
  ValStr           = lists:flatten(io_lib:format("~p.", [Value])),
  Tokens0          = get_tokens(ValStr),
  io:format("Tokens0:~p~n", [Tokens0]),
  Tokens           = maybe_replace_pid(Tokens0, Value),
  io:format("Tokens:~p~n", [Tokens]),
  {ok, [ValForm]}  = erl_parse:parse_exprs(Tokens),
  io:format("ValForm:~p~n", [ValForm]),
  replace_line_num(ValForm, L).

get_tokens(ValStr) ->
  {ok, Tokens, _} = erl_scan:string(ValStr),
  Tokens.

%% pid is displayed as atom instead. coz it is not a valid erlang term
maybe_replace_pid(Tokens0, Value) ->
  case is_pid_tokens(Tokens0) of
    true  ->
      ValStr0 = lists:flatten(io_lib:format("{__pid__, ~p}", [Value])),
      io:format("pid token:~p~n", [Tokens0]),
      ValStr1 = re:replace(ValStr0, "\\.", ",", [{return, list}, global]),
      ValStr2 = re:replace(ValStr1, "\\<", "{", [{return, list}, global]),
      ValStr  = re:replace(ValStr2, "\\>", "}", [{return, list}, global]),
      get_tokens(ValStr++".");
    false ->
      Tokens0
  end.

is_pid_tokens(Tokens) ->
  [FirstElem | _] = Tokens,
  [{dot, _}, LastElem | _] = lists:reverse(Tokens),
  is_left_arrow(FirstElem) andalso is_right_arrow(LastElem).

is_left_arrow({Char, _}) when Char =:= '<' ->
  true;
is_left_arrow(_) ->
  false.

is_right_arrow({Char, _}) when Char =:= '>' ->
  true;
is_right_arrow(_) ->
  false.

replace_line_num({A, _L0, C, D}, L)               ->
  {A, L, replace_line_num(C, L), replace_line_num(D, L)};
replace_line_num({A, _L0, C},    L)               ->
  {A, L, replace_line_num(C, L)};
replace_line_num({A, _L0},       L)               ->
  {A, L};
replace_line_num(Others,  L) when is_list(Others) ->
  lists:map(fun(Other) ->
                replace_line_num(Other, L)
            end, Others);
replace_line_num(Other,  _L)                      ->
  Other.

to_term(Arguments0, RT) ->
  Arguments = binary_to_list(Arguments0),
  io:format("args:~p~n", [Arguments]),
  %% N.B. this is very hackish. added a '.' because
  %%      erl_scan:string/1 requires full expression with dot
  {ok, Tokens,__Endline} = erl_scan:string(Arguments++"."),
  io:format("tokens:~p~n", [Tokens]),
  {ok, AbsForm0}         = erl_parse:parse_exprs(Tokens),
  AbsForm                = replace_var_with_val_in_expr(AbsForm0, []),
  io:format("absf:~p~n", [AbsForm0]),
  Val     = erl_eval:exprs( AbsForm
                          , erl_eval:new_bindings()),
  io:format("Valg:~p~n", [Val]),
  {value, Value,_Bs} = Val,
  io:format("val:~p~n", [Value]),
  Value.

%%%_* Unit tests ===============================================================

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
