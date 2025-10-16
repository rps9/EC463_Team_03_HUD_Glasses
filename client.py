import socket
import threading
from rich.console import Console

console = Console(highlight=False)
HOST = '127.0.0.1' # localhost 
PORT = 1234 # random port 

def listen_for_messages_from_server(client: socket.socket):
    while True:
        message = client.recv(2048).decode('utf-8')

        if message != '':
            raw_info = message.split("`*%n", 1)
            username = raw_info[0]
            content = raw_info[1]

            console.print(f"\n[bright_green][{username}][/bright_green] {content}")
            
        else:
            console.print("[red]Message from client is empty")

def send_message_to_server(client: socket.socket):
    while True: 
        message = console.input("[gray]Enter Message: [/]")

        if message != '':
            client.sendall(message.encode())

def communicate_to_server(client: socket.socket):
    while True:
        username = console.input("🚨[red]Please enter a username:[/] ")

        if username != '':
            client.sendall(username.encode()) # sender username to server
            
            # Wait for server response
            response = client.recv(2048).decode('utf-8')
            if response == "USERNAME_TAKEN":
                console.print("[red]Username is already taken! Please choose another one.[/red]")
                continue
            else:
                # Username accepted, break out of loop
                break
        else:
            console.print("[red]Please enter a valid username[/]")
            continue

    threading.Thread(target=listen_for_messages_from_server, args=(client, )).start()

    send_message_to_server(client)

def main():
    # Start the client using IPv4 and TCP
    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

    # Attempt to connect to the server
    try:
        client.connect((HOST, PORT))
        console.print(f"[green]Successfully connected to[/green] [cyan]{HOST}:{PORT}[/cyan]")
    except:
        console.print(f"[red]Unable to connect to[/red] [cyan]{HOST}:{PORT}[/cyan]")

    communicate_to_server(client)
if __name__ == '__main__':
    main()