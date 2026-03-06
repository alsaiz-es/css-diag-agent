#!/usr/bin/env python
import socket, sys, threading

def handle(conn, addr):
    try:
        try:
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                conn.sendall(data)
        except Exception:
            pass
    finally:
        conn.close()

def main():
    bind = '0.0.0.0'
    port = 9400
    args = sys.argv[1:]
    while args:
        if args[0] == '--bind' and len(args) > 1:
            bind = args[1]; args = args[2:]
        elif args[0] == '--port' and len(args) > 1:
            port = int(args[1]); args = args[2:]
        else:
            args = args[1:]
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((bind, port))
    s.listen(128)
    sys.stdout.write("Echo server listening on %s:%d\n" % (bind, port))
    sys.stdout.flush()
    try:
        try:
            while True:
                conn, addr = s.accept()
                t = threading.Thread(target=handle, args=(conn, addr))
                t.setDaemon(True)
                t.start()
        except KeyboardInterrupt:
            pass
    finally:
        s.close()

if __name__ == '__main__':
    main()
