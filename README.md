appleverifier
=====

An OTP application that polls an AWS SQS queue for a given Apple InApp Receipt, validate it against Apple's "verifyReceipt" API (see https://developer.apple.com/documentation/storekit/original_api_for_in-app_purchase/validating_receipts_with_the_app_store), lookup a DynamoDB table to see if the corresponding Apple "transaction_id" was already validated, and send the result "INVALID" or "OK" to an output AWS SQS queue.

The incoming messages from the first SQS queue have the following JSON format:
```
{
  "receipt" : String,
  "user_id" : Number,
  "post_queue: String
}
```

Where "receipt" is a base64 encoded Apple receipt and "user_id" is a number
representing a single user in the system. "post_queue" is the name of the AWS SQS queue where the result will be posted.

After validating, the application removes the initial message from the first SQS queue.

Messages will be written to the "post_queue" according to the following JSON:

```
{
  "user_id". Number,
  "transaction_id": String,
  "status": String
}
```

Build
-----

This project uses `rebar3` as its building tool. Follow [these](https://rebar3.readme.io/docs/getting-started) instructions to install it.

    $ rebar3 compile

Run in shell (Development)
--------------------------

    $ rebar3 shell

Build a Release (Production)
----------------------------

    $ rebar3 as prod release

Create a tar archive (Production)
---------------------------------

    $ rebar3 as prod tar

Note on logging
----------------

The application uses the default erlang logger.
You may change the sys.config file to change the logger's configuration.
The default log level is "notice".
To change the logging while running the application in the shell (e.g. running `rebar3 shell`), you may issue `logger:set_primary_config(level, debug).` to change the log level to `debug`.