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

%% This server talks to the "rte int listener" to retrieve the binding info.
%% It keeps track of all the neccessary information for displaying the
%% function bodies with temp variables replaced. It also keeps track of the
%% record definition using an ets table, much like what the shell does.

%%%_* Module declaration =======================================================
-module(edts_rte_server).

-behaviour(gen_server).

%%%_* Exports =================================================================

%% server API
-export([start/0, stop/0, start_link/0]).

-export([started_p/0]).

%% APIs for the int listener
-export([ break_at/1
        , finished_attach/1
        , read_and_add_records/1
        , rte_run/3
        , send_exit/0
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%%_* Includes =================================================================
-include_lib("eunit/include/eunit.hrl").

%%%_* Defines ==================================================================
-define(SERVER, ?MODULE).

-record(mfa_info, { key           :: mfa_info_key()
                  , fun_form      :: term()  %% FIXME type
                  , clauses_lines :: term()  %% FIXME type
                  , line          :: line()
                  , bindings      :: bindings()
                  }).

-record(rte_state, { proc                  = unattached :: unattached
                                                         | pid()
                   , record_table          = undefined  :: atom()
                   , depth                 = 0          :: depth()
                   , calling_mfa_info_list = []         :: [mfa_info()]
                   , called_mfa_info_list  = []         :: list()  %% FIXME type
                   , result                = undefined  :: term()
                   , module_cache          = []         :: list()  %% FIXME type
                   , exit_p                = false      :: boolean()
                   }).

%%%_* Types ====================================================================
-type bindings()     :: [{atom(), any()}].
-type depth()        :: non_neg_integer().
-type line()         :: non_neg_integer().
-type mfa_info()     :: #mfa_info{}.
-type mfa_info_key() :: {module(), function(), arity(), depth()}.
-type state()        :: #rte_state{}.

-export_type([ {bindings, 0}
             ]).

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
%% Run function through the RTE mechanism.
-spec rte_run(Module::module(), Fun::function(), Args::list()) -> {ok,finished}.
%%------------------------------------------------------------------------------
rte_run(Module, Fun, Args) ->
  gen_server:call(?SERVER, {rte_run, Module, Fun, Args}).

%%------------------------------------------------------------------------------
%% @doc Used by int listener to tell edts_rte_server that it has attached
%%      to the process that executes the rte function.
-spec finished_attach(pid()) -> ok.
finished_attach(Pid) ->
  gen_server:cast(?SERVER, {finished_attach, Pid}).

%%------------------------------------------------------------------------------
%% @doc Used by int listener to tell edts_rte_server that it has hit a break
%%      point with the bindings, module, line number and call stack depth
%%      information.
-spec break_at({bindings(), module(), line(), depth()}) -> ok.
break_at(Msg) ->
  gen_server:cast(?SERVER, {break_at, Msg}).

%%------------------------------------------------------------------------------
%% @doc Used by int listener to tell edts_rte_server that it has finished
%%      executing the function.
-spec send_exit() -> ok.
send_exit() ->
  gen_server:cast(?SERVER, exit).

%% FIXME: need to come up with a way to add all existing records from
%%        a project and remove records when recompile a particular module
read_and_add_records(Module) ->
  edts_rte_erlang:read_and_add_records(Module, record_table_name()).

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
  %% start the int listener. If rte server dies, the int listner will die as
  %% well. this is good because we will have a clean state to start with again.
  edts_rte_int_listener:start(),

  %% records in erlang are purely syntactic sugar. create a table to store the
  %% mapping between records and their definitions.
  %% set the table to public to make debugging easier
  RcdTbl = ets:new(record_table_name(), [public, named_table]),
  {ok, #rte_state{record_table = RcdTbl}}.

handle_call({rte_run, Module, Fun, Args0}, _From, State) ->
  %% try to read the record from the current module.. right now this is the
  %% only record support
  RcdTbl   = State#rte_state.record_table,
  AddedRds = edts_rte_erlang:read_and_add_records(Module, RcdTbl),
  edts_rte:debug("added record definitions:~p~n", [AddedRds]),

  Args     = binary_to_list(Args0),
  ArgsTerm = edts_rte_erlang:convert_list_to_term(Args, RcdTbl),
  edts_rte:debug("arguments:~p~n", [ArgsTerm]),

  %% set breakpoints
  [Module] = edts_rte_int_listener:interpret_modules([Module]),
  Arity    = length(ArgsTerm),
  {ok, set, {Module, Fun, Arity}} =
    edts_rte_int_listener:set_breakpoint(Module, Fun, Arity),

  %% run mfa
  RTEFun   = make_rte_run(Module, Fun, ArgsTerm),
  Pid      = erlang:spawn(RTEFun),
  edts_rte:debug("called function pid:~p~n", [Pid]),
  {reply, {ok, finished}, State#rte_state{ depth                 = 0
                                         , calling_mfa_info_list = []
                                         , module_cache          = []
                                         , proc                  = Pid
                                         , called_mfa_info_list  = []
                                         , result                = undefined
                                         , exit_p                = false
                                         }}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Handling all non call/cast messages
%% @end
%%
-spec handle_info(term(), state()) -> {noreply, state()} |
                                      {noreply, state(), Timeout::timeout()} |
                                      {stop, Reason::atom(), state()}.
handle_info(_Msg, State) ->
  %% edts_rte:debug("rte_server handle_info ...., Msg:~p~n", [Msg]),
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
  Pid = State#rte_state.proc,
  edts_rte_int_listener:step(),
  edts_rte:debug("finish attach.....~n"),
  {noreply, State};
handle_cast({break_at, {Bindings, Module, Line, Depth}},State0) ->
  {MFA, State1} = get_mfa(State0, Module, Line),
  edts_rte:debug("1) send_binding.. before step. old depth:~p , new_depth:~p~n"
           , [State1#rte_state.depth, Depth]),
  edts_rte:debug("2) send_binding.. Line:~p, Bindings:~p~n",[Line, Bindings]),

  edts_rte:debug("3) new mfa:~p~n", [MFA]),

  %% get mfa and add one level if it is not main function
  %% output sub function body when the process leaves it.
  %% Only step into one more depth right now.
  %% {CalledMFAInfoList, CallingMFAInfoList0} =
  State2 =
    case State1#rte_state.depth > Depth of
      true  ->
        edts_rte:debug( "send replaced fun..~nbinding:~p~nDepth:~p~n"
                      , [Bindings, Depth]),

        %% Pop function up till function's depth <= Depth
        {OutputMFAInfo, RestMFAInfo} =
          lists:splitwith(fun(MFAInfoS) ->
                              {_M, _F, _A, D} = MFAInfoS#mfa_info.key,
                              D > Depth
                          end, State1#rte_state.calling_mfa_info_list),
        edts_rte:debug("4) OutputMFAInfo:~p~n", [OutputMFAInfo]),
        edts_rte:debug("5) RestMFAInfo:~p~n", [RestMFAInfo]),

        %% assert
        true = (length(OutputMFAInfo) =:= 1),

        %% output function bodies
        CalledMFAInfoList =
          OutputMFAInfo ++ State1#rte_state.called_mfa_info_list,
        State1#rte_state{ called_mfa_info_list  = CalledMFAInfoList
                        , calling_mfa_info_list = RestMFAInfo};
      false ->
        State1
    end,

  State = update_mfa_info_list(MFA, Depth, Line, Bindings, State2),

  %% continue to step
  edts_rte_int_listener:step(),

  {noreply, State#rte_state{depth = Depth}};
handle_cast(exit, #rte_state{result = RteResult} = State0) ->
  edts_rte:debug("rte server got exit~n"),
  State = on_exit(RteResult, State0),
  {noreply, State#rte_state{exit_p=true}};
handle_cast({rte_result, Result}, #rte_state{exit_p = ExitP} = State) ->
  edts_rte:debug("rte server got RTE Result:~p~n", [Result]),
  ExitP andalso on_exit(Result, State),
  {noreply, State#rte_state{result=Result}};
handle_cast(_Msg, State) ->
  {noreply, State}.

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

%%%_* Internal =================================================================
%%------------------------------------------------------------------------------
%% @doc Send the rte result to the rte server.
-spec send_rte_result(term()) -> ok.
send_rte_result(Result) ->
  gen_server:cast(?SERVER, {rte_result, Result}).

%% @doc Calculate the MFA based on the line number in the module name. If the
%%      depth is not changed, it is assumed that we remain in the same function
%%      as before, therefore there is no need to re-calculate.
%%      NOTE:
%%      There seems to be a problem with int module. If a function call is
%%      involved in the last expression of a function, when the debugger
%%      process step into the function call, the depth is not changed.
%%
%%      One way to work around this is to cache all the sorted function
%%      info for a particular module and do not use the change of the depth
%%      as the indicator that a new mfa should be calculated. It is too
%%      expensive if no such caching is performed,
get_mfa(State, Module, Line) ->
  case orddict:find(Module, State#rte_state.module_cache) of
    error ->
      ModFunInfo  = edts_rte_erlang:get_module_sorted_fun_info(Module),
      NewModCache = orddict:store( Module, ModFunInfo
                                 , State#rte_state.module_cache),
      [_L, F, A]  = find_function(Line, ModFunInfo),
      {{Module, F, A}, State#rte_state{module_cache = NewModCache}};
    {ok, ModFunInfo} ->
      [_L, F, A]  = find_function(Line, ModFunInfo),
      {{Module, F, A}, State}
  end.

find_function(_L, [])                      ->
  [];
find_function(L, [[L0, _F, _A] = LFA | T]) ->
  case L >= L0 of
    true  -> LFA;
    false -> find_function(L, T)
  end.

%% @doc Generate the replaced functions based on the mfa_info list
-spec make_replaced_funs([mfa_info()]) -> string().
make_replaced_funs(MFAInfoList) ->
  lists:foldl(fun(MFAInfo, Funs) ->
                Key = MFAInfo#mfa_info.key,
                ReplacedFun = make_replaced_fun(Key, MFAInfo),
                [{Key, ReplacedFun} | Funs]
              end, [], MFAInfoList).

%% @doc Generate the replaced function based on the mfa_info
make_replaced_fun(MFAD, MFAInfoS) ->
  #mfa_info{ key           = Key
           , bindings      = Bindings
           , fun_form      = FunAbsForm
           , clauses_lines = AllClausesLn} = MFAInfoS,
  %% assert
  Key = MFAD,
  edts_rte_erlang:var_to_val_in_fun(FunAbsForm, AllClausesLn, Bindings).

%% @doc Called when an RTE run is about to finish. Generate the replaced
%%      functions and send them to the clients.
-spec on_exit(undefined | string(), state()) -> state().
on_exit(undefined, State) ->
  State;
on_exit(Result, State) ->
  AllMFAInfo = State#rte_state.called_mfa_info_list ++
               State#rte_state.calling_mfa_info_list,
  AllReplacedFuns = lists:reverse(make_replaced_funs(AllMFAInfo)),
  ok = send_result_to_clients(Result, concat_replaced_funs(AllReplacedFuns)),
  State.

%% @doc Concat a list of replaced function strings together.
-spec concat_replaced_funs([{Key, string()}]) -> string()
         when Key :: {module(), function(), arity()}.
concat_replaced_funs(ReplacedFuns) ->
  lists:foldl(
    fun({{M, F, A, D}, RplFun}, RplFuns) ->
        lists:flatten(
          io_lib:format( "~s~n~s~n~s~n"
                       , [make_comments(M, F, A, D), RplFun, RplFuns]))
    end, [], ReplacedFuns).

make_result({M, F, A, RteResult}) ->
  lists:flatten(io_lib:format("%% ========== Generated by RTE ==========~n"
                              "%% ~p:~p/~p ---> ~p~n~n", [M, F, A, RteResult])).

%% @doc Make the comments to display on the client
make_comments(M, F, A, D) ->
  lists:flatten(io_lib:format("%% MFA   : {~p, ~p, ~p}:~n"
                              "%% Level : ~p", [M, F, A, D])).

%% @doc  Either create a new mfa_info at the top of the calling mfa_info list
%%       or update the first element of the calling mfa_info list based on the
%%       new information. @see `add_new_mfa_info_p'
%%
%% NOTE: if the clauses are unfortunately programmed in the same line
%%       then rte shall feel confused and refuse to display any value of
%%       the variables.
-spec update_mfa_info_list( {module(), function(), arity()}, depth()
                          , line(), bindings(), [mfa_info()]) -> [mfa_info()].
update_mfa_info_list({M, F, A}, Depth, Line, Bindings, State0) ->
  Key = {M, F, A, Depth},
  edts_rte:debug( "6) upd calling mfa_info list params:~p~n"
                , [[State0#rte_state.calling_mfa_info_list, Key, Line]]),
  PopCallingMFAInfoP   = pop_calling_mfa_info_p(
                           State0#rte_state.calling_mfa_info_list,
                           Key, Line, Depth),
  edts_rte:debug("7) pop calling mfa info p..:~p~n", [PopCallingMFAInfoP]),
  State =
    case PopCallingMFAInfoP of
      false ->
        State0;
      true  ->
        NewCallingMFAInfoL = tl(State0#rte_state.calling_mfa_info_list),
        NewCalledMFAInfoL  = [ hd(State0#rte_state.calling_mfa_info_list)
                             | State0#rte_state.called_mfa_info_list],
        State0#rte_state{ calling_mfa_info_list = NewCallingMFAInfoL
                        , called_mfa_info_list  = NewCalledMFAInfoL }
    end,

  CallingMFAInfoL = State#rte_state.calling_mfa_info_list,
  AddCallingMFAInfoP = add_new_calling_mfa_info_p(CallingMFAInfoL, Key, Line),
  edts_rte:debug("8) add new calling mfa info p..:~p~n", [AddCallingMFAInfoP]),

  UpdatedCallingMFAInfoL =
    case AddCallingMFAInfoP of
      true ->
        %% add new mfa_info
        {ok, FunAbsForm} = edts_code:get_function_body(M, F, A),
        AllClausesLn0    = edts_rte_erlang:extract_fun_clauses_line_num(
                             FunAbsForm),
        AllClausesLn     = edts_rte_erlang:traverse_clause_struct(
                             Line, AllClausesLn0),
        [ #mfa_info{ key           = Key
                   , line          = Line
                   , fun_form      = FunAbsForm
                   , clauses_lines = AllClausesLn
                   , bindings      = Bindings}
        | CallingMFAInfoL];
      false ->
        #mfa_info{key= Key, clauses_lines = AllClausesLn}
          = Val = hd(CallingMFAInfoL),
        TraversedLns =
          edts_rte_erlang:traverse_clause_struct(Line, AllClausesLn),
        [ Val#mfa_info{ clauses_lines = TraversedLns
                      , line          = Line
                      , bindings      = Bindings}
        | tl(CallingMFAInfoL)]
    end,
  State#rte_state{calling_mfa_info_list = UpdatedCallingMFAInfoL}.

%% @doc Return true when a new calling mfa_info needs to be added.
%%      This will happen when:
%%      1) The NewKey is not the same as that of the first element of the
%%         mfa_info_list.
%%      2) Tail recursion
-spec add_new_calling_mfa_info_p( [mfa_info()], mfa_info_key(), line()) ->
                                    boolean().
add_new_calling_mfa_info_p(MFAInfoList, NewKey, NewLine) ->
  case key_of_first_elem_p(NewKey, MFAInfoList) of
    false ->
      true;
    true  ->
      MFAInF = hd(MFAInfoList),
      TailP  = edts_rte_erlang:is_tail_recursion( MFAInF#mfa_info.clauses_lines
                                                , MFAInF#mfa_info.line
                                                , NewLine),
      %% assert that it is not tail recursion
      false = TailP,
      false
  end.

pop_calling_mfa_info_p(CallingMFAInfoList, NewKey, NewLine, NewDepth) ->
  case try_get_hd(CallingMFAInfoList) of
    false ->
      false;
    {ok, MFAInfo} ->
      case MFAInfo#mfa_info.key =:= NewKey of
        true  ->
          edts_rte_erlang:is_tail_recursion( MFAInfo#mfa_info.clauses_lines
                                           , MFAInfo#mfa_info.line
                                           , NewLine);
        false ->
          {_M, _F, _A, Depth} = MFAInfo#mfa_info.key,
          NewDepth =:= Depth
      end
  end.

%% @doc check if the key is the key of the first element in the MFAInfoList
%%      list.
-spec key_of_first_elem_p(mfa_info_key(), [mfa_info()]) -> boolean().
key_of_first_elem_p(Key, MFAInfoList) ->
  case try_get_hd(MFAInfoList) of
    {ok, MFAInfo} -> MFAInfo#mfa_info.key =:= Key;
    false         -> false
  end.

%% @doc Get the hd a list: `HEAD'. If the list is empty, return false.
%%      Otherwise return {ok, `Head'}
-spec try_get_hd(list()) -> false | {ok, any()}.
try_get_hd([])     ->
  false;
try_get_hd([H|_T]) ->
  {ok, H}.

%% @doc The name of the ETS table to store the tuple representation of
%%      the records
-spec record_table_name() -> atom().
record_table_name() ->
  edts_rte_record_table.

%% @doc Send the function body back to Clients.
send_result_to_clients(RteResult, FunBody) ->
  edts_rte:debug("final rte result:~p~n", [RteResult]),
  edts_rte:debug("final function body is:~p~n", [FunBody]),
  Result = string_escape_chars(RteResult ++ FunBody, escaped_chars()),
  lists:foreach( fun(Fun) -> Fun(Result) end
               , [ fun send_result_to_rte_web/1
                 , fun send_result_to_emacs/1
                 ]).

%% @doc Send the function body back to Emacs.
send_result_to_emacs(FunBody) ->
  BufferName = io_lib:format("*~s*", [make_id()]),
  EclientCmd = make_emacsclient_cmd(BufferName, FunBody),
  edts_rte:debug("FunBody:~p~n", [FunBody]),
  edts_rte:debug("emacsclient CMD:~p~n", [EclientCmd]),
  os:cmd(EclientCmd).

%% @doc Construct the emacsclient command to send the function
%%      body back to Emacs.
make_emacsclient_cmd(Id, FunBody) ->
  lists:flatten(io_lib:format(
                  "emacsclient -e '(edts-display-erl-fun-in-emacs"
                  " \"~s\" \"~s\" )'", [FunBody, Id])).

%% @doc Send the function body to rte web client.
send_result_to_rte_web(FunBody) ->
  httpc:request(post, { url(), [], content_type()
                      , mk_editor(make_id(), FunBody)}, [], []).

%% @doc Make the client id.
-spec make_id() -> string().
make_id() ->
  lists:flatten(io_lib:format("rte_result_~s", [node_str()])).

%% @doc Return the string representation of the node, replacing
%%      @ with __at__
-spec node_str() -> string().
node_str() ->
  re:replace(atom_to_list(node()), "@", "__at__", [{return, list}]).

url() ->
  "http://localhost:4587/rte/editors/".

content_type() ->
  "application/json".

%% @doc make an editor in json format which is comprehensible for
%%      the rte web client.
-spec mk_editor(string(), string()) -> string().
mk_editor(Id, FunBody) ->
 lists:flatten( io_lib:format(
                  "{\"x\":74,\"y\":92,\"z\":1,\"id\":\"~s\",\"code\":\"~s\"}"
              , [Id, FunBody])).

%% @doc Make the function to execute the MFA.
-spec make_rte_run(module(), function(), [term()]) -> fun(() -> ok).
make_rte_run(Module, Fun, ArgsTerm) ->
  fun() ->
    Result = try
               erlang:apply(Module, Fun, ArgsTerm)
             catch
               T:E -> lists:flatten(io_lib:format("~p:~p", [T, E]))
             end,
    edts_rte:debug("RTE Result:~p~n", [Result]),
    send_rte_result(make_result({Module, Fun, length(ArgsTerm), Result}))
  end.

%% @doc Escape the chars in a given list from a string.
-spec string_escape_chars(string(), [string()]) -> string().
string_escape_chars(Msg, Chars) ->
  Fun = fun(C, MsgAcc) ->
          re:replace(MsgAcc, "\\"++C, "\\\\"++C, [global, {return, list}])
        end,
  lists:foldl(Fun, Msg, Chars).

escaped_chars() ->
  ["\""].

%%%_* Unit tests ===============================================================

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
