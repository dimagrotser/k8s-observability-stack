# Screenshots

These are referenced from the top-level README.

| File | What it shows |
|---|---|
| `dashboard-red.png` | `demo-api / RED` under load, with a 50% error rate |
| `dashboard-use.png` | `demo-api / USE`, CPU and memory against their limits |
| `alert-firing.png` | Alertmanager with `HighErrorRate` firing |

To retake them, run the demo and capture while it is going:

```bash
make demo-alert     # about six minutes
```

The alert stays firing for roughly five minutes after the load stops, and the
error spike stays inside a 15 minute dashboard window for about as long, so
there is no rush to catch the exact moment.
