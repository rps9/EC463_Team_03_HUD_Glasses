import socket
import threading
from rich.console import Console

console = Console(highlight=False)
HOST = '127.0.0.1' # localhost 
PORT = 1234 # random port 
LISTENER_LIMIT = 5
active_clients = {} # keeps track of connected users

def listen_for_messages(client: socket.socket, username: str):
    '''
    '''
    while True:
        message = client.recv(2048).decode('utf-8')

        if message != '':
            # Add funcitonality for private messaging
            if message.startswith('@'):
                parts = message.split(' ', 1)
                if len(parts) >= 2:
                    target_username = parts[0][1:]  # Remove @ symbol
                    if target_username in active_clients:
                        final_message = f"{username}`*%n{parts[1]}"
                        send_message_to_client(final_message, active_clients[target_username])
                    else:
                        error_message = f"SERVER`*%nUser '{target_username}' not found"
                        send_message_to_client(error_message, client)
            else:
                # Regular message - send to all
                final_message = f"{username}`*%n{message}"
                send_message_to_all(final_message)
        else:
            console.print(f"[red]The message from user[/red] [cyan]{username}[/cyan] [red]is empty[/red]")

def send_message_to_client(message: str, client: socket.socket):
    '''
    '''
    client.sendall(message.encode()) # utf-8 is default

def send_message_to_all(message):
    for client in active_clients.values():
        send_message_to_client(message, client)

def client_handler(client: socket.socket):
    # Wait and listen for the username
    while True:
        username = client.recv(2048).decode('utf8')
        if username != '':
            if username in active_clients:
                console.print("[red]Username taken, try again![/red]")
                send_message_to_client("USERNAME_TAKEN", client)
                continue
            active_clients[username] = client
            send_message_to_all(f"SERVER`*%n{username} has been added to the chat!")

            break 
        else:
            console.print("[red]Please enter a valid username[/red]")

    threading.Thread(target=listen_for_messages, args=(client, username, )).start()


def main():
    # Start the server using IPv4 and TCP
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

    # Attempt to bind the server
    try:
        server.bind((HOST, PORT))
        console.print(f"[green]Successfully binded to[/green] [cyan]{HOST}:{PORT}[/cyan]")
    except:
        console.print(f"[red]Unable to bind to[/red] [cyan]{HOST}:{PORT}[/cyan]")

    server.listen(LISTENER_LIMIT)

    while True:
        client, address = server.accept()
        console.print(f"[green]Successfully connected to client[/green] [blue]{address[0]}:{address[1]}[/blue]")

        threading.Thread(target=client_handler, args=(client, )).start()

if __name__ == '__main__':
    main()