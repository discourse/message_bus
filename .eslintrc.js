/*global module*/
module.exports = {
  env: {
    browser: true,
    es2021: false,
  },
  extends: 'eslint:recommended',
  parserOptions: {
    ecmaVersion: 2015,
    sourceType: 'module',
  },
  rules: {},
  ignorePatterns: ['/vendor', '/doc', '/assets/jquery-1.8.2.js'],
  overrides: [
    {
      // Enable async/await in tests only
      files: ["spec/**/*"],
      parserOptions: {
        ecmaVersion: 2022,
      },
    },
  ],
};
