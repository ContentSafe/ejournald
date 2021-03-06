% Copyright 2010-2014, Travelping GmbH <info@travelping.com>

% Permission is hereby granted, free of charge, to any person obtaining a
% copy of this software and associated documentation files (the "Software"),
% to deal in the Software without restriction, including without limitation
% the rights to use, copy, modify, merge, publish, distribute, sublicense,
% and/or sell copies of the Software, and to permit persons to whom the
% Software is furnished to do so, subject to the following conditions:

% The above copyright notice and this permission notice shall be included in
% all copies or substantial portions of the Software.

% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
% DEALINGS IN THE SOFTWARE.

%% @private
-module(ejournald_notifier).
-behaviour(gen_server).

-include("internal.hrl").

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, code_change/3]).
-export([start_link/2]).

-record(state, {
    ctx, 
    sink,
    message,
    regex
}).

%% ----------------------------------------------------------------------------------------------------
%% -- gen_server callbacks
start_link(Sink, Options) ->
    gen_server:start_link(?MODULE, {Sink, Options}, []).

init({Sink, Options}) ->
    case is_pid(Sink) of
        true -> 
            link(Sink),
            process_flag(trap_exit, true);
        _ -> ok
    end,
    JournalDir = proplists:get_value(dir, Options),
    Msg = proplists:get_value(message, Options, false),
    Regex = proplists:get_value(regex, Options, undefined),
    case JournalDir of
        undefined   -> 
            {ok, Ctx} = journald_api:open(),
            adjust_journal(Ctx, Options),
            State = #state{ctx = Ctx, sink = Sink, message = Msg, regex = Regex},
            {ok, State};
        _JournalDir -> 
            BinDir = list_to_binary(JournalDir),
            case journald_api:open_directory(<<BinDir/binary, "\0">>) of
                {error, Reason} ->
                    {stop, Reason};
                {ok, Ctx} ->
                    adjust_journal(Ctx, Options),
                    State = #state{ctx = Ctx, sink = Sink, message = Msg, regex = Regex},
                    {ok, State}
            end
    end.

handle_call({terminate, Reason}, _From, State) ->
    {stop, Reason, ok, State};
handle_call(_Msg, _From, State) ->
    {noreply, State}.

handle_info(journal_append, State = #state{sink = Sink}) when is_pid(Sink) -> 
    Logs = flush_journal(State),
    [ Sink ! Log || Log <- Logs ],
    {noreply, State};
handle_info(journal_append, State = #state{sink = Sink}) when is_function(Sink,1) -> 
    Logs = flush_journal(State),
    [ catch(Sink(Log)) || Log <- Logs ],
    {noreply, State};
handle_info(journal_invalidate, State = #state{sink = Sink}) when is_pid(Sink) -> 
    Sink ! journal_invalidate,
    {noreply, State};
handle_info(journal_invalidate, State = #state{sink = Sink}) when is_function(Sink,1) -> 
    catch(Sink(journal_invalidate)),
    {noreply, State};
handle_info({'EXIT',_FromPid,_Reason}, State) -> 
    {stop, normal, State};
handle_info(_Msg, State) -> 
    {noreply, State}.

%% unused
terminate(_Reason, _State) -> ok.
handle_cast(_Msg, State) -> {noreply, State}.
code_change(_,_,State) -> {ok, State}. 

%% ------------------------------------------------------------------------------
%% -- notifier api
adjust_journal(Ctx, Options) ->
    ok = journald_api:seek_tail(Ctx),
    ok = journald_api:previous(Ctx),
    ok = journald_api:open_notifier(Ctx, self()),
    ejournald_helpers:reset_matches(Options, Ctx).

flush_journal(#state{ctx = Ctx, message = Msg, regex = Regex}) ->
    collect_logs({Msg, Regex}, Ctx, []).

%% ----------------------------------------------------------------------------------------------------
%% -- retrieving logs
next_entry(Ctx) ->
    case journald_api:next(Ctx) of
        ok -> 
            ejournald_helpers:generate_entry(Ctx);
        Error -> Error
    end.

next_msg(Ctx) ->
    case journald_api:next(Ctx) of
        ok -> 
            ejournald_helpers:generate_msg(Ctx);
        Error ->
            Error
    end.

collect_logs(Opts = {Msg, Regex}, Ctx, Akk) ->
    case Msg of
        false -> Result = next_entry(Ctx);
        true -> Result = next_msg(Ctx)
    end,
    case Result of
        no_more -> lists:reverse(Akk);
        _Else   -> 
            case ejournald_helpers:check_regex(Regex, Result) of
                ignore -> collect_logs(Opts, Ctx, Akk);
                Log -> collect_logs(Opts, Ctx, [Log | Akk])
            end
    end.


