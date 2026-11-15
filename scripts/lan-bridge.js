const net = require('net');
const os = require('os');

// Find non-internal IPv4 address
function getLocalIP() {
    const interfaces = os.networkInterfaces();
    for (const name of Object.keys(interfaces)) {
        for (const iface of interfaces[name]) {
            if (iface.family === 'IPv4' && !iface.internal) {
                return iface.address;
            }
        }
    }
    return '0.0.0.0';
}

const localIP = getLocalIP();
const targetPort = 8080;
const targetHost = '127.0.0.1';

function createBridge(port, host) {
    const server = net.createServer(client => {
        const target = net.connect(targetPort, targetHost);
        client.pipe(target);
        target.pipe(client);
        client.on('error', () => target.destroy());
        target.on('error', () => client.destroy());
    });

    server.listen(port, host, () => {
        console.log(`[LAN Bridge] Forwarding ${host}:${port} -> ${targetHost}:${targetPort}`);
    });

    server.on('error', err => {
        console.error(`[LAN Bridge] Error on ${host}:${port}: ${err.message}`);
    });
    return server;
}

// Listen on local IP at 8080 and all interfaces at 8888
if (localIP !== '0.0.0.0' && localIP !== '127.0.0.1') {
    createBridge(8080, localIP);
}
createBridge(8888, '0.0.0.0');

console.log(`Server accessible to Smart TV at:`);
console.log(`  http://${localIP}:8080/view`);
console.log(`  http://${localIP}:8888/view`);
