-module(vmstats).
-behaviour(application).

-export([
    start/0,
    start/2,
    stop/1
]).

start() ->
    ok = application:start(statsderl),
    ok = application:start(vmstats).

start(normal, []) ->
    vmstats_sup:start_link("vmstats").

stop(_) ->
    ok.
