// Commit messages and PR titles follow Conventional Commits: https://www.conventionalcommits.org
// The rules, and how they set version numbers, are in docs/devops.md ("Versioning and releases").
// Checked by the commit-msg hook (.husky/commit-msg) and, for PR titles, by CI.
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // Optional, but if given it must be one of these.
    'scope-enum': [2, 'always', ['app', 'server', 'docs', 'ci', 'repo', 'deps', 'release']],
    // Allow proper nouns and acronyms in the subject ("add Valkey store", "IPv6").
    'subject-case': [0],
  },
};
