%%%-------------------------------------------------------------------
%% @doc appleverifier top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(appleverifier_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% TODO: Add configuration for number of processes to launch through supervisor

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 1,
                 period => 5},
    %% For now run only 10 child processes
    ChildSpecs = create_child_specs(10),
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions

%% (NOTE: this only allows up to 100 child specs for the app)
%% Returns for 1 =< N =< 100
%% #{id => appleverifier_server_<N>, start => {appleverifier_server, start_link, []}}
%% Avoids creating atoms with same "name"
new_child_spec(N)
  when is_integer(N) and (N >= 1) and (N =< 100) ->
    NBinary = list_to_binary(integer_to_list(N)),
    String = <<"appleverifier_server">>,
    StringAppendedWithN = <<String/binary, NBinary/binary>>,
    AsAtom =
    try binary_to_existing_atom(StringAppendedWithN) of
      A ->
        A
    catch
      _:_ -> binary_to_atom(StringAppendedWithN)
    end,
    #{id => AsAtom, start => {appleverifier_server, start_link, [AsAtom]}}.

%% Create <Count> child specs
create_child_specs(Count) when is_integer(Count) ->
    lists:map(fun (N) -> new_child_spec(N) end, lists:seq(1, Count)).