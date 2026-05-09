"""Provides colored console output and log-level formatting for the pipeline."""

from __future__ import annotations

from datetime import UTC, datetime
from enum import Enum
import sys


class LogLevel(Enum):
    """Defines log levels with their associated display labels and ANSI color codes."""

    DEBUG = ("DEBUG", "\033[36m")
    """Marks debug-level diagnostic messages."""

    INFO = ("INFO", "\033[35m")
    """Marks general informational messages."""

    SUCCESS = ("SUCCESS", "\033[32m")
    """Marks successful completion messages."""

    WARNING = ("WARNING", "\033[33m")
    """Marks non-fatal warning messages."""

    ERROR = ("ERROR", "\033[31m")
    """Marks error messages that may terminate the program."""

    def __init__(self, label: str, color_code: str) -> None:
        """Initializes a log level with a label and color code.

        Args:
            label: The output message displayed for the log level.
            color_code: The ANSI color escape code for the log level.
        """
        self.label = label
        self.color_code = color_code


class Console:
    """Manages colored console output for pipeline logging."""

    def __init__(self) -> None:
        """Initializes the console output manager."""
        self._reset_code: str = "\033[0m"

    def log(self, message: str, level: LogLevel | None = None, prefix: bool = True) -> None:
        """Prints a formatted message to the console.

        Args:
            message: The output message to display.
            level: The log level used to format the message.
            prefix: A boolean flag indicating whether the log level prefix is included.
        """
        # Defaults to INFO if no level is provided.
        level = level or LogLevel.INFO

        timestamp = datetime.now(tz=UTC).astimezone().strftime("%H:%M:%S.%f")[:-3]

        if prefix:
            formatted_message = (
                f"\033[90m{timestamp}\033[0m {level.color_code}[{level.label}]{self._reset_code} {message}"
            )
        else:
            formatted_message = f"\033[90m{timestamp}\033[0m {level.color_code}{message}{self._reset_code}"

        print(formatted_message)  # noqa: T201

    def success(self, message: str, prefix: bool = True) -> None:
        """Prints a success message to the console.

        Args:
            message: The success message to display.
            prefix: A boolean flag indicating whether the log level prefix is included.
        """
        self.log(message, level=LogLevel.SUCCESS, prefix=prefix)

    def warning(self, message: str, prefix: bool = True) -> None:
        """Prints a warning message to the console.

        Args:
            message: The warning message to display.
            prefix: A boolean flag indicating whether the log level prefix is included.
        """
        self.log(message, level=LogLevel.WARNING, prefix=prefix)

    def error(
        self,
        message: str,
        error: Exception | None = None,
        exit_code: int = 1,
        prefix: bool = True,
    ) -> None:
        """Prints an error message and optionally terminates the program.

        Args:
            message: The error message to display.
            error: The exception that caused the error if provided.
            exit_code: The process exit code. A value of 0 prevents exiting.
            prefix: A boolean flag indicating whether the log level prefix is included.
        """
        self.log(message, level=LogLevel.ERROR, prefix=prefix)

        if error:
            self.log(
                f"Exception: {type(error).__name__}: {error!s}",
                level=LogLevel.ERROR,
                prefix=prefix,
            )

        if exit_code > 0:
            sys.exit(exit_code)


# Creates a single global instance of the console.
console = Console()
