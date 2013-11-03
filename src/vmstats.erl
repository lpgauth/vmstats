-module(vmstats).

%% public
-export([
    start/0
]).

-behaviour(application).
-export([
    start/2,
    stop/1
]).

%% public
start() ->
    ok = application:start(statsderl),
    ok = application:start(vmstats).

%% application callbacks
start(_StartType, _StartArgs) ->
    vmstats_sup:start_link().

stop(_State) ->
    ok.
