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
