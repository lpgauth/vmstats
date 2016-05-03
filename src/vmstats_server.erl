-module(vmstats_server).
-behaviour(gen_server).
-include_lib("system_stats/include/system_stats.hrl").

%% public
-export([
    start_link/0
]).

%% private
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-define(DELAY, 1000).
-define(PAGE_SIZE, 4096).
-define(TIMER_MSG, '#delay').

-record(state, {
    tstamp :: erlang:timestamp(),
    base_key :: iolist(),
    gc_stats :: {NumberGcs::integer(), WordsReclaimed::integer(), 0},
    io_stats :: {Input::integer(), Output::integer()},
    scheduler_stats,
    system_stats :: #stats {},
    timer_ref :: reference()
}).

%% public
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% private
init([]) ->
    BaseKey = case application:get_env(vmstats, base_key) of
        {ok, Key} -> [Key, $.];
        undefined -> <<"">>
    end,

    {ok, #state {
        tstamp = os:timestamp(),
        base_key = BaseKey,
        gc_stats = gc_stats(),
        io_stats = io_stats(),
        scheduler_stats = init_scheduler_stats(),
        system_stats = init_system_stats(),
        timer_ref = erlang:start_timer(?DELAY, self(), ?TIMER_MSG)
    }}.

handle_call(_Msg, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, TimerRef, ?TIMER_MSG}, #state {
        tstamp = Timestamp,
        base_key = BaseKey,
        gc_stats = {NumberGCs, WordsReclaimed, _},
        io_stats = {IoInput, IoOutput},
        scheduler_stats = SchedulerStats,
        system_stats = SystemStats,
        timer_ref = TimerRef
    } = State) ->

    % uptime
    Uptime = timer:now_diff(os:timestamp(), Timestamp) / 60000000,
    statsderl:gauge([BaseKey, <<"uptime_minutes">>], Uptime, 1.00),

    % processes
    statsderl:gauge([BaseKey, <<"proc_count">>], erlang:system_info(process_count), 1.00),
    statsderl:gauge([BaseKey, <<"proc_limit">>], erlang:system_info(process_limit), 1.00),

    % modules loaded
    statsderl:gauge([BaseKey, <<"modules">>], length(code:all_loaded()), 1.00),

    % run queue
    statsderl:gauge([BaseKey, <<"run_queue">>], erlang:statistics(total_run_queue_lengths), 1.00),

    % error_logger message queue length
    {_, MessageQueueLength} = process_info(whereis(error_logger), message_queue_len),
    statsderl:gauge([BaseKey, <<"error_logger_queue_len">>], MessageQueueLength, 1.00),

    % vm memory usage
    MemoryKey = [BaseKey, <<"memory.">>],
    Memory = erlang:memory(),
    statsderl:gauge([MemoryKey, <<"total">>], bytes_to_megabytes(proplists:get_value(total, Memory)), 1.00),
    statsderl:gauge([MemoryKey, <<"procs_used">>], bytes_to_megabytes(proplists:get_value(processes_used, Memory)), 1.00),
    statsderl:gauge([MemoryKey, <<"atom_used">>], bytes_to_megabytes(proplists:get_value(atom_used, Memory)), 1.00),
    statsderl:gauge([MemoryKey, <<"binary">>], bytes_to_megabytes(proplists:get_value(binary, Memory)), 1.00),
    statsderl:gauge([MemoryKey, <<"ets">>], bytes_to_megabytes(proplists:get_value(ets, Memory)), 1.00),

    % io stats
    IoStats = {IoInput2, IoOutput2} = io_stats(),
    statsderl:increment([BaseKey, <<"io.bytes_in">>], IoInput2 - IoInput, 1.00),
    statsderl:increment([BaseKey, <<"io.bytes_out">>], IoOutput2 - IoOutput, 1.00),

    % gc stats
    GCStats = {NumberGCs2, WordsReclaimed2, _} = gc_stats(),
    statsderl:increment([BaseKey, <<"gc.count">>], NumberGCs2 - NumberGCs, 1.00),
    statsderl:increment([BaseKey, <<"gc.words_reclaimed">>], WordsReclaimed2 - WordsReclaimed, 1.00),

    % reductions
    {_, Reductions} = erlang:statistics(reductions),
    statsderl:increment([BaseKey, <<"reductions">>], Reductions, 1.00),

    % system stats
    SystemStats2 = system_stats(BaseKey, SystemStats),

    % scheduler_wall_time
    SchedulerStats2 = scheduler_stats(),
    ShedulerUtils = lists:map(fun({{I, A0, T0}, {I, A1, T1}}) ->
	    {I, (A1 - A0) / (T1 - T0)}
    end, lists:zip(SchedulerStats, SchedulerStats2)),

    lists:map(fun ({SchedulerId, ShedulerUtil}) ->
        SchedulerIdBin = integer_to_binary(SchedulerId),
        statsderl:gauge([BaseKey, <<"scheduler_utilization.">>, SchedulerIdBin], ShedulerUtil, 1.00)
    end, ShedulerUtils),

	% active_tasks
	lists:foldl(fun(ActiveTasks, SchedulerId) ->
        SchedulerIdBin = integer_to_binary(SchedulerId),
		statsderl:gauge([BaseKey, <<"active_tasks.">>, SchedulerIdBin], ActiveTasks, 1.00),
		SchedulerId + 1
	end, 1, erlang:statistics(active_tasks)),

	% run_queue_lengths
	lists:foldl(fun(RunQueueLengths, SchedulerId) ->
        SchedulerIdBin = integer_to_binary(SchedulerId),
		statsderl:gauge([BaseKey, <<"run_queue_lengths.">>, SchedulerIdBin], RunQueueLengths, 1.00),
		SchedulerId + 1
	end, 1, erlang:statistics(run_queue_lengths)),

    {noreply, State#state {
        gc_stats = GCStats,
        io_stats = IoStats,
        scheduler_stats = SchedulerStats2,
        system_stats = SystemStats2,
        timer_ref = erlang:start_timer(?DELAY, self(), ?TIMER_MSG)
    }};
handle_info(_Msg, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% private
init_scheduler_stats() ->
    erlang:system_flag(scheduler_wall_time, true),
    lists:sort(erlang:statistics(scheduler_wall_time)).

init_system_stats() ->
    case system_stats:supported_os() of
        undefined ->
            #stats {};
        _Else ->
            SystemStats = system_stats:proc_cpuinfo(system_stats_utils:new_stats()),
            SystemStats2 = system_stats:proc_stat(SystemStats),
            system_stats:proc_pidstat(os:getpid(), SystemStats2)
    end.

bytes_to_megabytes(Bytes) ->
    Bytes / 1048576.

gc_stats() ->
    erlang:statistics(garbage_collection).

io_stats() ->
    {{input, IoInput}, {output, IoOutput}} = erlang:statistics(io),
    {IoInput, IoOutput}.

scheduler_stats() ->
    lists:sort(erlang:statistics(scheduler_wall_time)).

system_stats(BaseKey, SystemStats) ->
    case system_stats:supported_os() of
        undefined ->
            #stats {};
        _Else ->
            % system load
            SystemStats2 = system_stats:proc_loadavg(SystemStats),
            statsderl:gauge([BaseKey, <<"system.load_1">>], SystemStats2#stats.load_1, 1.00),
            statsderl:gauge([BaseKey, <<"system.load_5">>], SystemStats2#stats.load_5, 1.00),
            statsderl:gauge([BaseKey, <<"system.load_15">>], SystemStats2#stats.load_15, 1.00),

            % system cpu %
            SystemStats3 = system_stats:proc_pidstat(os:getpid(), SystemStats2),
            SystemStats4 = system_stats:proc_stat(SystemStats3),
            {CpuUser, CpuSystem} = system_stats_utils:cpu_percent(SystemStats, SystemStats4),
            CpuPercent = trunc(SystemStats4#stats.cpu_cores * (CpuUser + CpuSystem)),
            statsderl:gauge([BaseKey, <<"system.cpu_percent">>], CpuPercent, 1.00),

            % system memory
            Vsize = trunc(bytes_to_megabytes(SystemStats4#stats.mem_vsize)),
            Rss = trunc(bytes_to_megabytes(?PAGE_SIZE * (SystemStats4#stats.mem_rss))),
            statsderl:gauge([BaseKey, <<"system.vsize">>], Vsize, 1.00),
            statsderl:gauge([BaseKey, <<"system.rss">>], Rss, 1.00),

            SystemStats4
    end.
