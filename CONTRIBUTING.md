# Contributing to zig-tftp

Thank you for your interest in contributing! This project welcomes contributions from everyone.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/zig-tftp.git`
3. Create a feature branch: `git checkout -b feature/my-feature`
4. Make your changes
5. Run tests: `zig build test`
6. Commit your changes with a clear message
7. Push and open a Pull Request

## Development Setup

### Prerequisites
- [Zig](https://ziglang.org/download/) version 0.15.2 or later

### Building and Testing
```bash
# Build the project
zig build

# Run the server
zig build run

# Run the test suite
zig build test
```

## Code Style

- Follow the [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide)
- Use descriptive variable and function names
- Add comments for complex logic
- Keep functions focused and small

## Testing

This project follows Test-Driven Development (TDD). Please:
- Add tests for new functionality
- Ensure all existing tests pass before submitting a PR
- Test packet parsing, transfer logic, and integration scenarios

## Pull Request Process

1. Update the README.md if your changes affect usage
2. Ensure `zig build test` passes
3. Write a clear PR description explaining your changes
4. Link any related issues

## Reporting Issues

When reporting bugs, please include:
- Zig version (`zig version`)
- Operating system
- Steps to reproduce
- Expected vs actual behavior

## Questions?

Feel free to open an issue for questions or discussion!
