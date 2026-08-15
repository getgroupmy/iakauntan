/**
 * Starting up, and stopping without cutting anybody off mid-sentence.
 */
import { loadConfig } from './config.js';
import { Rooms } from './rooms.js';
import { createCallServer } from './server.js';

const config = loadConfig();
const rooms = await new Rooms(config).start();
const server = createCallServer({ config, rooms });
await server.listen();

let stopping = false;
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, async () => {
    if (stopping) process.exit(1);
    stopping = true;
    console.log(
      JSON.stringify({
        at: new Date().toISOString(),
        level: 'info',
        event: 'stopping',
        signal,
        rooms: rooms.size,
      }),
    );
    // Sockets first, so clients see a close and can put "Call ended" on
    // screen, then the workers. The other order kills the media and
    // leaves everybody looking at a frozen frame.
    await server.close();
    await rooms.close();
    process.exit(0);
  });
}
