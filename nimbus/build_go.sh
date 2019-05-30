#!/bin/sh 
go build --ldflags '-extldflags "-static"' -o test main.go
