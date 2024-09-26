package main

import (
	"errors"
	"fmt"
	"os"
	"remote_scheduler/initiator"
	"remote_scheduler/master"
	"remote_scheduler/test"
	"remote_scheduler/worker"
)

var commands = map[string]func([]string){
	"master":    master.Main,
	"initiator": initiator.Main,
	"worker":    worker.Main,
	"test":      test.Main,
}
var ErrInvalidMessage = errors.New("invalid message")

func main() {
	if len(os.Args) == 1 {
		fmt.Println(usage())
		os.Exit(1)
	}
	cmd, ok := commands[os.Args[1]]
	if !ok {
		fmt.Println(usage())
		os.Exit(1)
	}
	cmd(os.Args[2:])
}

func usage() string {
	s := "Usage: remote_scheduler [command] [options]\nAvailable commands:\n"
	for k := range commands {
		s += " - " + k + "\n"
	}
	return s
}
