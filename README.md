# process-compose-macos

A macOS window onto a [process-compose](https://github.com/F1bonacc1/process-compose) dev stack.
A sidebar picks one project at a time; the list groups that project's processes by namespace,
streams their logs, and starts or stops them one at a time or all at once.

Unofficial project. Not affiliated with or endorsed by process-compose.

## Requirements

- macOS 14 or later
- A process-compose server with its REST API reachable

## Build

```
make build     # debug build
make test      # ProcessComposeCore test suite
make run       # run without bundling
make app       # assemble the .app into build/
make install   # build and copy the app to /Applications
```

There is no Xcode project. Swift Package Manager builds the binary and `Scripts/bundle.sh`
assembles the `.app` around it.

## Connecting

The app talks to `localhost:28080`. `PC_PORT_NUM` sets the port on first launch, and
Settings (Cmd+,) sets it from then on.

## Stopping and starting the stack

The power button stops every running process but leaves the server up, so it can start them
again. process-compose exits once its last process stops, so launch the stack with
`--keep-project` or the server will not be there to start anything.
