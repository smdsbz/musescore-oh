import { socket } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';

export class PngSender {
  static async sendFile(host: string, port: number, path: string): Promise<string> {
    try {
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const st = fileIo.statSync(f.fd);
      const buf = new ArrayBuffer(st.size);
      const v = new Uint8Array(buf);
      let got = 0;
      while (got < st.size) {
        const n = fileIo.readSync(f.fd, buf, { offset: got, length: st.size - got });
        if (n <= 0) {
          break;
        }
        got += n;
      }
      fileIo.closeSync(f.fd);

      const sc: socket.TCPSocket = socket.constructTCPSocketInstance();
      sc.on('connect', () => {
        console.info('PNGSOCK connected');
      });
      await sc.connect({ address: { address: host, port: port, family: 1 }, timeout: 8000 });
      const hdr = `PNGSEND ${got}\n`;
      const header: Uint8Array = new Uint8Array(hdr.length);
      for (let i = 0; i < hdr.length; i++) {
        header[i] = hdr.charCodeAt(i);
      }
      const payload: Uint8Array = new Uint8Array(header.length + got);
      payload.set(header, 0);
      payload.set(v.subarray(0, got), header.length);
      await sc.send({ data: payload.buffer });
      sc.close();
      return `sent ${got} bytes to ${host}:${port}`;
    } catch (e) {
      return `send failed: ${JSON.stringify(e)}`;
    }
  }
}
