"""App shell: pushes the setup screen and wires global bindings/styles."""

from textual.app import App
from textual.binding import Binding

from .setup_screen import SetupScreen


class PlaylistGenApp(App[None]):
    TITLE = "Playlist Gen"
    SUB_TITLE = "Apple Music → video"
    CSS_PATH = "app.tcss"
    BINDINGS = [Binding("q", "quit", "Quit")]

    def on_mount(self) -> None:
        self.push_screen(SetupScreen())


def main() -> None:
    PlaylistGenApp().run()


if __name__ == "__main__":
    main()
