module.exports = {
  apps: [
    {
      name: "raffled-indexer",
      cwd: __dirname,
      script: "npm",
      args: "run start",
      exec_mode: "fork",
      instances: 1,
      autorestart: true,
      max_memory_restart: "1G",
      env: {
        NODE_ENV: "production",
        DATABASE_SCHEMA: "main",
      },
    },
  ],
};
