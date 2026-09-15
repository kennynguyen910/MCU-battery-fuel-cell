"""Print UDP messages sent to this laptop on port 5005."""

import socket


def main():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
        try:
            receiver.bind(("0.0.0.0", 5005))
            print("Listening on UDP port 5005", flush=True)

            while True:
                data, address = receiver.recvfrom(2048)
                message = data.decode("utf-8", errors="replace")
                print(f"{address[0]}:{address[1]} - {message}", flush=True)
        except KeyboardInterrupt:
            print("\nUDP receiver stopped.")


if __name__ == "__main__":
    main()
