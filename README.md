# tesladb

Tesladb isn't really a database.  Rather it is a way to grab data from
Tesla's user API and store it in both sqlite and MQTT.

In most common consumption, the other side of MQTT is sent to InfluxDB
or some other kind of time series database for later visualization in
Grafana or the like.

## Building

This is a [Haskell stack tools](https://docs.haskellstack.org/) based
project.  Given a working `stack`, one should be able to execute
`stack build` which will fetch all of the dependencies and build.

After building, you will have several executables.

teslauth: Authenticates to Tesla's API (with your credentials) and
stores them in a local database.  _For obvious reasons_ treat this
carefully. It is fairly safe, however, in that it does not store
credenials, but does store a token to a session from the password you
initially supply.

teslacatcher: Drains an MQTT topic to a sqlite database.  This can
also backfill missing data, effectively synchronizing state locally.

tesladb: Runs continuiously polling Tesla's API to write to a database
and MQTT, by default.

tesladbfix: Filters out fields that have bad timestamps to a table
named "rejects" in the database.

## Setup and Run

With Haskell `stack`, you can run the binaries from the source
checkout using `stack exec`.  Alternatively use `stack install` to
install to Stack's local bin directory.  Examples below are post install.

The first thing you'll need to do is auth.  This runs once initially,
then needs to be run once a day with the -r flag to refresh.

```
teslauth --email "myaddress@example.com" \
--dbpath ~/var/tesla.db
```

Then, as mentioned, run approximately once per day (from cron or such
which checks for `0` exit status)  to refresh the auth token as follows:

```
teslauth -r --dbpath ~/var/tesla.db
```

After that, running tesladb itself is usually a matter of running the
main command with arguments.

```
tesladb --vname "mycar" \
--dbpath ~/var/tesladb.db \
--mqtt-uri mqtts://user:pass@host/#tesladb \
--mqtt-topic tesla/x/data \
--listen-topic 'tesla/x/in/#' \
--enable-commands -v
```

One problem you'll probably run into is that you don't know your
vehicle name to pass to `--vname`.  If you run the command without the
vehicle name, it will introspect the Tesla API to give you a list of
possible vehicles.

This will run every 600s or so as long as the auth is valid and the
API isn't returning errors.  The API _does_ tend to return errors
regularly. If that is the case, just back off and run it again using
whatever makes sense on your system to do such things (e.g. upstart,
smf).

## What Does This Do?

The resulting MQTT topics both receive telemetry and status as well as
take input messages for car control.  Need to open your frunk?  Don't
bother with the Tesla app, just craft an MQTT message to do it for
you.  Imagine the automation possibilities.
