// Minimal static-file server for the compiled Flutter web application. Keeping
// this separate from the data API makes each component easy to explain and run.
import express from 'express';
import { fileURLToPath } from 'node:url';

// Serve Flutter's release output locally. No additional frontend toolchain is
// required; the app uses hash routes, so browser navigation keeps index.html.
const app = express();
app.get('/preview-health', (_req, res) => res.json({service: 'capstone-web'}));
const build = fileURLToPath(new URL('../../monitor/build/web-viewer/', import.meta.url));
app.use(express.static(build));
app.listen(5173, '127.0.0.1', () => console.log('Flutter previews: http://localhost:5173'));
