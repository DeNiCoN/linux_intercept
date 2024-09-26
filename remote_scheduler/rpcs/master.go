package rpcs

type Master struct {
}

type ConnectArgs struct{}
type ConnectReply struct {
	Message string
}

func (w *Master) StartJobset(args *ConnectArgs, reply *ConnectReply) error {
	reply.Message = "Ok"
	return nil
}

func (w *Master) Connect(args *ConnectArgs, reply *ConnectReply) error {
	reply.Message = "Ok"
	return nil
}
