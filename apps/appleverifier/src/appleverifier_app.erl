%%%-------------------------------------------------------------------
%% @doc appleverifier public API
%% @end
%%%-------------------------------------------------------------------

-module(appleverifier_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    appleverifier_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
