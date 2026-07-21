import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    // Dev-only: forward API calls to the backend running separately on :3000.
    proxy: { "/api": "http://localhost:3000" },
  },
});
