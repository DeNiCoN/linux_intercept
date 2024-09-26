package worker

import (
	"io"
	"log"
	"net"
	"os/exec"
	"remote_scheduler/master"
	"sync"
	"time"

	"github.com/lesismal/arpc"
)

const PARALLEL_WORKERS = 16

type Worker struct {
}

type RunJobArgs struct {
	Name string
	Args []string
}

type RunJobResponse struct {
	ExitCode int
	Stdout   []byte
	Stderr   []byte
}

func (worker *Worker) RunJob(ctx *arpc.Context) {
	args := RunJobArgs{}
	ctx.Bind(args)

	command := exec.Command(args.Name, args.Args...)
	err := command.Run()
	if err != nil {
		log.Fatalln(err)
	}

	stdout, _ := command.StdoutPipe()
	stdout_c := make(chan []byte, 0)
	go func() {
		result, err := io.ReadAll(stdout)
		if err != nil {
			log.Fatal(err)
		}
		stdout_c <- result
	}()

	stderr, _ := command.StderrPipe()
	stderr_c := make(chan []byte, 0)
	go func() {
		result, err := io.ReadAll(stderr)
		if err != nil {
			log.Fatal(err)
		}
		stderr_c <- result
	}()

	err = command.Wait()
	if err != nil {
		log.Fatalln(err)
	}

	reply := RunJobResponse{
		ExitCode: command.ProcessState.ExitCode(),
		Stdout:   <-stdout_c,
		Stderr:   <-stderr_c,
	}

	ctx.Write(reply)
}

func StartWorker(wg *sync.WaitGroup) {
	worker := Worker{}
	server := arpc.NewServer()
	// register router
	server.Handler.Handle("/run_job", worker.RunJob)

	server.Run("localhost:7891")

	wg.Done()
}

func Main([]string) {
	var wg sync.WaitGroup
	wg.Add(1)

	go StartWorker(&wg)

	client, err := arpc.NewClient(func() (net.Conn, error) {
		return net.DialTimeout("tcp", "localhost:7890", time.Second*3)
	})
	if err != nil {
		panic(err)
	}
	defer client.Stop()

	err = client.Call("/connect", &master.ConnectArgs{}, &master.ConnectResponse{}, time.Second*5)
	if err != nil {
		log.Fatalf("Connect failed: %v", err)
	}
	log.Println("Connected")

	log.Println("Waiting for jobs")
	wg.Wait()
}
