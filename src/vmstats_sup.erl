-module(vmstats_sup).
-behaviour(supervisor).

%% public
-export([
    start_link/0
]).

%% private
-export([
    init/1
]).

-define(CHILD(I, Args), {I, {I, start_link, Args}, permanent, 5000, worker, [I]}).

%% public
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% private
init([]) ->
    {ok, {{one_for_all,5,3600}, [
        ?CHILD(vmstats_server, [])]
    }}.
