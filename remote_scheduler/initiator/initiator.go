package initiator

import (
	"fmt"
	"log"
	"net"
	"remote_scheduler/master"
	"time"

	"github.com/lesismal/arpc"
)

type Initiator interface {
	//Client facing
	Execute(executable string, arguments []string)

	//Worker facing
	CacheFile(path string)
}

func RunJob(client *arpc.Client, exe string, args []string) {
	req := master.NewTaskArgs{}
	rsp := master.NewTaskResponse{}

	err := client.Call("/new_task", &req, &rsp, time.Second*5)
	if err != nil {
		log.Fatalf("Call failed: %v", err)
	}
	log.Println(rsp)

	// client, err := arpc.NewClient(func() (net.Conn, error) {
	// 	return net.DialTimeout(addr.Network(), addr.String(), time.Second*3)
	// })

	if err != nil {
		log.Panicln("Can't connect")
	}
}

func Main(Args []string) {
	client, err := arpc.NewClient(func() (net.Conn, error) {
		return net.DialTimeout("tcp", "localhost:7890", time.Second*3)
	})
	if err != nil {
		panic(err)
	}
	defer client.Stop()

	for i := range 100 {
		RunJob(client, "echo", []string{"meow", fmt.Sprintf("%v", i)})
	}
}
