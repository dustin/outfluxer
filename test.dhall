let Query : Type = {
    queryText : Text,
    targets : List {
        field : Text,
        destination : Text
    }
}

let Source : Type = {
    host : Text,
    db : Text,
    queries : List Query
}

let Config : Type = { sources : List Source }

let simpleQuery = λ(args : {q : Text, f : Text, d : Text}) →
    { queryText=args.q, targets=[{field=args.f, destination=args.d}]}

let map = https://prelude.dhall-lang.org/List/map
let concat = https://prelude.dhall-lang.org/List/concat

let avg = "30m"
let recent = "now() - 1h"

let starlinkSrc : Source = {
    host = "aws1",
    db = "starlink",
    queries = [
            simpleQuery {q="select last(software_version) from \"spacex.starlink.user_terminal.status\" where time > ${recent}",
                        f="last", d="tmp/starlink/version"}
    ]
}

in { sources = [ starlinkSrc ] }
