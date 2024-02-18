#!/bin/bash
cs launch org.scalameta:mdoc_3:2.5.2 -- --in README.template.md --out README.md --classpath $(cs fetch --classpath co.fs2::fs2-io:3.9.4) $*
