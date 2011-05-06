%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 1996-2009. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%
-module(ns_log_mf_h).

-behaviour(gen_event).

-export([init/3, init/4]).

-export([init/1, handle_event/2, handle_info/2, terminate/2]).
-export([handle_call/2, code_change/3]).
-export([start_link/0]).

%%-----------------------------------------------------------------

-type dir()  :: file:filename().
-type b()    :: non_neg_integer().
-type f()    :: 1..255.
-type pred() :: fun((term()) -> boolean()).

%%-----------------------------------------------------------------

-record(state, {dir    :: dir(),
		maxB   :: b(),
		maxF   :: f(),
		curB   :: b(),
		curF   :: f(),
		cur_fd :: file:fd(),
		index = [],  %% Seems unused - take out??
		pred   :: pred()}).

%%%-----------------------------------------------------------------
%%% This module implements an event handler that writes events
%%% to multiple files (configurable).
%%%-----------------------------------------------------------------
%% Func: init/3, init/4
%% Args: Dir  = string()
%%       MaxB = integer()
%%       MaxF = byte()
%%       Pred = fun(Event) -> boolean()
%% Purpose: An event handler.  Writes binary events
%%          to files in the directory Dir.  Each file is called
%%          1, 2, 3, ..., MaxF.  Writes MaxB bytes on each file.
%%          Creates a file called 'index' in the Dir.
%%          This file contains the last written FileName.
%%          On startup, this file is read, and the next available
%%          filename is used as first logfile.
%%          Each event is filtered with the predicate function Pred.
%%          Reports can be browsed with Report Browser Tool (rb).
%% Returns: Args = term()
%%          The Args term should be used in a call to
%%            gen_event:add_handler(EventMgr, log_mf_h, Args)
%%              EventMgr = pid() | atom().
%%-----------------------------------------------------------------


%% Replace the default event handler with ours
start_link() ->
    misc:start_event_link(
      fun () ->
              case lists:member(?MODULE, gen_event:which_handlers(error_logger)) of
                  false ->
                      {ok, Dir} = application:get_env(error_logger_mf_dir),
                      {ok, MaxB} = application:get_env(error_logger_mf_maxbytes),
                      {ok, MaxF} = application:get_env(error_logger_mf_maxfiles),
                      Pred = fun (_) -> true end,
                      io:write({Dir, MaxB, MaxF, Pred}),
                      ok = gen_event:add_sup_handler(error_logger, ?MODULE, {Dir, MaxB, MaxF,
                                                                             Pred}),
                      case misc:get_env_default(dont_suppress_stderr_logger, false) of
                          false ->
                              error_logger:delete_report_handler(sasl_report_tty_h),
                              error_logger:delete_report_handler(error_logger_tty_h);
                          _ -> ok
                      end,
                      ignore;
                  true ->
                      ignore
              end
      end).

-spec init(dir(), b(), f()) -> {dir(), b(), f(), pred()}.

init(Dir, MaxB, MaxF) -> init(Dir, MaxB, MaxF, fun(_) -> true end).

-spec init(dir(), b(), f(), pred()) -> {dir(), b(), f(), pred()}.

init(Dir, MaxB, MaxF, Pred) -> {Dir, MaxB, MaxF, Pred}.

%%-----------------------------------------------------------------
%% Call-back functions from gen_event
%%-----------------------------------------------------------------

-spec init({dir(), b(), f(), pred()}) -> {'ok', #state{}} | {'error', term()}.

init({Dir, MaxB, MaxF, Pred}) when is_integer(MaxF), MaxF > 0, MaxF < 256 ->
    First =
	case read_index_file(Dir) of
	    {ok, LastWritten} -> inc(LastWritten, MaxF);
	    _ -> 1
	end,
    case catch file_open(Dir, First) of
	{ok, Fd} ->
	    {ok, #state{dir = Dir, maxB = MaxB, maxF = MaxF, pred = Pred,
			curF = First, cur_fd = Fd, curB = 0}};
	Error -> Error
    end.

%%-----------------------------------------------------------------
%% The handle_event/2 function may crash!  In this case, this
%% handler is removed by gen_event from the event handlers.
%% Fails: 'file_open' if file:open failed for a log file.
%%        'write_index_file' if file:write_file failed for the
%%            index file.
%%        {file_exit, Reason} if the current Fd crashes.
%%-----------------------------------------------------------------

-spec handle_event(term(), #state{}) -> {'ok', #state{}}.

handle_event(Event, State) ->
    #state{curB = CurB, maxB = MaxB, curF = CurF, maxF = MaxF,
	   dir = Dir, cur_fd = CurFd, pred = Pred} = State,
    case catch Pred(Event) of
	true ->
	    {Bin, Size} = encode_event(Event),
	    NewState =
		if
		    CurB + Size < MaxB -> State;
		    true ->
			ok = file:close(CurFd),
			NewF = inc(CurF, MaxF),
			{ok, NewFd} = file_open(Dir, NewF),
			State#state{cur_fd = NewFd, curF = NewF, curB = 0}
		end,
	    [Hi,Lo] = put_int16(Size),
	    file:write(NewState#state.cur_fd, [Hi, Lo, Bin]),
	    {ok, NewState#state{curB = NewState#state.curB + Size + 2}};
	_ ->
	    {ok, State}
    end.

-spec handle_info(term(), #state{}) -> {'ok', #state{}}.

handle_info({emulator, GL, Chars}, State) ->
    handle_event({emulator, GL, Chars}, State);
handle_info(_, State) ->
    {ok, State}.

-spec terminate(term(), #state{}) -> #state{}.

terminate(_, State) ->
    ok = file:close(State#state.cur_fd),
    State.

-spec handle_call('null', #state{}) -> {'ok', 'null', #state{}}.

handle_call(null, State) ->
    {ok, null, State}.

-spec code_change(term(), #state{}, term()) -> {'ok', #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%-----------------------------------------------------------------
%% Misc local functions
%%-----------------------------------------------------------------

encode_event(Event) ->
    Bin = term_to_binary(tag_event(Event)),
    case byte_size(Bin) of
	Size when Size =< 16#ffff ->
	    {Bin, Size};
	_ ->
	    String = lists:sublist(lists:flatten(io_lib:print(Event, 0, 80, 100)),
				   65000),
	    Event1 = {error, group_leader(), {self(), "Truncated log event:~n~s",
					      [String]}},
	    Bin1 = term_to_binary(tag_event(Event1)),
	    {Bin1, byte_size(Bin1)}
    end.

file_open(Dir, FileNo) ->
    case file:open(Dir ++ [$/ | integer_to_list(FileNo)], [raw, write]) of
	{ok, Fd} ->
	    write_index_file(Dir, FileNo),
	    {ok, Fd};
	_ ->
	    exit({file, open})
    end.

put_int16(I) ->
    [((I band 16#ff00) bsr 8),I band 16#ff].

tag_event(Event) ->
    {erlang:localtime(), Event}.

read_index_file(Dir) ->
    case file:open(Dir ++ "/index", [raw, read]) of
	{ok, Fd} ->
	    Res = case catch file:read(Fd, 1) of
		      {ok, [Index]} -> {ok, Index};
		      _ -> error
		  end,
	    ok = file:close(Fd),
	    Res;
	_ -> error
    end.

%%-----------------------------------------------------------------
%% Write the index file.  This file contains one binary with
%% the last used filename (an integer).
%%-----------------------------------------------------------------

write_index_file(Dir, Index) ->
    case file:open(Dir ++ "/index", [raw, write]) of
	{ok, Fd} ->
	    file:write(Fd, [Index]),
	    ok = file:close(Fd);
	_ -> exit(open_index_file)
    end.

inc(N, Max) ->
    if
	N < Max -> N + 1;
	true -> 1
    end.
