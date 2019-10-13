# outfluxer

An InfluxDB → MQTT gateway.

## Example

This is a snippet of the configuration I'm using in production.

```
from influxdbhost iotawatt {
     query "select last(value) from solar group by *" {
           last -> $site/iotawatt/solar/now
     }
     query "select mean(value) from solar where time > now() - 30m group by *" {
           mean -> $site/iotawatt/solar/30m
     }
}

from influxdbhost collectd {
     query "select last(value) from load_shortterm group by *" {
           last -> sys/$host/load
     }
     query "select last(value) from cpufreq_value group by *" {
           last -> sys/$host/$type/$type_instance
     }
}
```
