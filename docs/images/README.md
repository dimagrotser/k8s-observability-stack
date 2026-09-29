# Screenshots

Drop dashboard screenshots here and the placeholders in the top-level README
turn into images.

| File | What to capture |
|---|---|
| `dashboard-red.png` | `demo-api / RED` under load, with a visible error rate |
| `dashboard-use.png` | `demo-api / USE`, showing CPU and memory against their limits |
| `alert-firing.png` | Alertmanager with `HighErrorRate` firing |

The easiest way to get something worth showing:

```bash
make demo-alert     # drives errors for about six minutes
```

Take the screenshots while it runs, then replace the placeholder blocks in
`README.md` with the image links given there.
