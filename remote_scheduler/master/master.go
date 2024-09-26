package master

import (
	"log"
	"net"
	"time"

	"github.com/lesismal/arpc"
)

type Master struct {
	workers []arpc.Client
}

type ConnectArgs struct {
}

type ConnectResponse struct {
}

func (master *Master) Connect(ctx *arpc.Context) {
	client, err := arpc.NewClient(func() (net.Conn, error) {
		return net.DialTimeout("tcp", "localhost:7891", time.Second*3)
	})

	if err != nil {
		ctx.Error(err)
	}

	master.workers = append(master.workers, *client)

	ctx.Write(ConnectResponse{})
}

type NewTaskArgs struct {
}

type NewTaskResponse struct {
	Workers []net.TCPAddr
}

func (master *Master) NewTask(ctx *arpc.Context) {
	var args NewTaskArgs
	ctx.Bind(args)

	addresses := make([]net.TCPAddr, len(master.workers))

	for i, w := range master.workers {
		tcp_addr, ok := w.Conn.RemoteAddr().(*net.TCPAddr)
		if ok == false {
			log.Panicf("Addr not tcp %v", tcp_addr)
		}

		addresses[i] = *tcp_addr
	}

	resp := NewTaskResponse{
		addresses,
	}

	ctx.Write(resp)
}

func Main(Args []string) {
	master := Master{
		workers: make([]arpc.Client, 0),
	}

	server := arpc.NewServer()

	// register router
	server.Handler.Handle("/connect", master.Connect)
	server.Handler.Handle("/new_task", master.NewTask)
	//server.Handler.Handle("/run", master.Run)

	server.Run("localhost:7890")
}

//Test - Remote execution - stdout
// 1 Master, 1 Worker, 1 Initiator
// Start Master
// Connect Worker
