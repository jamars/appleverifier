-module(appleverifier_apple_requests).

-export([verify_receipt/2]).

verify_receipt(B64Receipt, API_URL) ->
    JSON = get_verify_receipt_request_as_json(B64Receipt),
    case make_request(JSON, API_URL) of
        {ok, R} ->
            logger:debug("~n~p Body: ~p~n", [?FUNCTION_NAME, R]),
            verify_successful_call(R);
        {error, Error} ->
            logger:error("~n~p Error: ~pn", [?FUNCTION_NAME, Error]),
            {error, Error}
    end.

%% Private module functions

get_verify_receipt_request_as_json([]) ->
    jsx:encode([{<<"receipt-data">>,<<"">>}]);

get_verify_receipt_request_as_json(B64Receipt) ->
    %% io:format("~n~p B64: ~p~n", [?FUNCTION_NAME, B64Receipt]),
    jsx:encode([{<<"receipt-data">>,B64Receipt}]).

make_request(JSON, API_URL) ->
    io:format("~n~p ~p~n BODY: ~p~n", [?FUNCTION_NAME, API_URL ++ "/verifyReceipt", JSON]),
    R = lhttpc:request(API_URL ++ "/verifyReceipt",post,[{"Content-Type", "application/json"}], JSON, 5000),
    case R of
        {ok, {_, _, Body}} ->
            {ok, jsx:decode(Body)};
        {error, Error} ->
            {error, Error}
    end.

verify_successful_call(Receipt) ->
    Status = proplists:get_value(<<"status">>, Receipt),
    io:format("~n~p Apple Status: ~p~n", [?FUNCTION_NAME, Status]),
    case Status of
        0 ->
            %% Receipt format: [[<<"receipt">>, [..., {<<"transaction_id">>, <<"<ID>">>, ...], {<<"status">>, <N>}]
            {ok, proplists:get_value(<<"transaction_id">>, proplists:get_value(<<"receipt">>, Receipt))};
        _ ->
            {invalid, proplists:get_value(<<"transaction_id">>, proplists:get_value(<<"receipt">>, Receipt))}
    end.