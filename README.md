# couch_dnssd

**License Apache 2**

couch_dnssd is a [CouchDB](http://couchdb.apache.org/) plugin that allows CouchDB instances to find each other over local-networks and the internet using DNS Service Discovery. Once installed you can get a list of accessible instances like this:

```
$ curl http://127.0.0.1:5984/_dnssd
[{"name":"another couch","domain":"local."},{"name":"another couch","domain":"bonjour.tj.id.au."}]
```

You can narrow down browsing to a specific browse domain by appending a domain:

```
$ curl http://127.0.0.1:5984/_dnssd/local
[{"name":"another couch","domain":"local."}]
```

If you then add the name of a service you'll get back it's details:

```
$ curl http://localhost:5984/_dnssd/local/another%20couch
{"hostname":"atj-mbp.local.","port":123,"params":["path=/_utils"]}
```

The `"path=/_utils"` returned in params is for the benefit of DNSSD aware web browsers such as Safari and Firefox ([with extension](https://addons.mozilla.org/en-US/firefox/addon/dnssd/)) which will navigate directly to that path.

Configuration is as follows:

```
[httpd]
; couch_dnssd won't advertise installs bound to 127.x.x.x or ::1
bind_address = 0.0.0.0

[daemons]
dnssd = {couch_dnssd, start_link, []}

[httpd_global_handlers]
_dnssd = {couch_dnssd, handle_dnssd_req}

[dnssd]
;name = OptionalName
;path = OptionalPath
```

To use couch_dnssd you will need to change the path to `couchdb.hrl` listed in rebar.config, then run `./rebar get-deps` followed by `./rebar compile`. Then add the above configuration to local.ini and finally start couch with something like:

```
env ERL_ZFLAGS="-pa /PathTo/couch_dnssd/ebin/ -pa /PathTo/couch_dnssd/deps/dnssd/ebin/" ./utils/run -i
```

The installation process and features provided will be improved upon as and when CouchDB grows more plugin friendly. If you're interested in seeing this developed further please [drop me a note](http://andrew.tj.id.au/email).