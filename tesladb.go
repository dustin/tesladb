package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"path"
	"time"

	"github.com/dustin/httputil"
	_ "github.com/mattn/go-sqlite3"
	"golang.org/x/sync/errgroup"

	"github.com/yosssi/gmq/mqtt"
	"github.com/yosssi/gmq/mqtt/client"
)

const (
	userAgent = "Mozilla/5.0 (Linux; Android 9.0.0; VS985 4G Build/LRX21Y; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/58.0.3029.83 Mobile Safari/537.36"
	teslaUA   = "TeslaApp/3.4.4-350/fad4a582e/android/9.0.0"

	urlBase = "https://owner-api.teslamotors.com/api/1/vehicles/"
)

var (
	bearer = flag.String("bearer", "", "auth bearer token")
	vid    = flag.String("vid", "", "vehicle ID")
	period = flag.Duration("period", time.Minute*10, "update period")
	base   = flag.String("base", "", "path to store data")
	dbpath = flag.String("dbpath", "", "path to store data in sqlite")

	db *sql.DB
)

func getTeslaURL(ctx context.Context, u string, o interface{}) error {
	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+*bearer)
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("X-Tesla-User-Agent", teslaUA)

	req = req.WithContext(ctx)

	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return httputil.HTTPError(res)
	}

	return json.NewDecoder(res.Body).Decode(o)
}

type StateRecord struct {
	Type string           `json:"type"`
	Data *json.RawMessage `json:"data"`
}

func storeData(ctx context.Context, mcli *client.Client, st *StateRecord) error {
	t := time.Now()
	dir := path.Join(*base, t.Format("2006/01/02"))
	if err := os.MkdirAll(dir, 0777); err != nil {
		return err
	}

	g := errgroup.Group{}

	g.Go(func() error {
		fn := path.Join(dir, t.Format("150405.json"))
		j, err := json.Marshal(st)
		if err != nil {
			return err
		}
		return ioutil.WriteFile(fn, j, 0666)
	})

	g.Go(func() error {
		j, err := json.Marshal(st.Data)
		if err != nil {
			return err
		}
		return mcli.Publish(&client.PublishOptions{
			QoS:       mqtt.QoS1,
			TopicName: []byte("tesla/x/data"),
			Message:   j,
		})
	})

	g.Go(func() error {
		if db == nil {
			return nil
		}
		j, err := json.Marshal(st.Data)
		if err != nil {
			return err
		}

		stmt, err := db.Prepare("insert into data(ts, data) values(?, ?)")
		if err != nil {
			return err
		}
		_, err = stmt.Exec(t, j)
		return err
	})

	return g.Wait()
}

type Response struct {
	Response *json.RawMessage
}

func update(ctx context.Context, mcli *client.Client) (time.Duration, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()

	st := &StateRecord{Type: "state"}

	bits := &struct {
		VehicleState struct {
			IsUserPresent bool `json:"is_user_present"`
		} `json:"vehicle_state"`
		ChargeState struct {
			ChargerPower int `json:"charger_power"`
		} `json:"charge_state"`
	}{}

	r := &Response{}
	if err := getTeslaURL(ctx,
		urlBase+*vid+"/vehicle_data", r); err != nil {
		return *period, err
	}
	st.Data = r.Response

	if err := json.Unmarshal(*r.Response, bits); err != nil {
		return *period, err
	}

	delay := *period
	switch {
	case bits.VehicleState.IsUserPresent:
		log.Printf("User is present.")
		delay = time.Minute
	case bits.ChargeState.ChargerPower > 0:
		log.Printf("Charging at %v", bits.ChargeState.ChargerPower)
		delay = time.Minute * 5
	}

	return delay, storeData(ctx, mcli, st)
}

func initDB() error {
	if *dbpath == "" {
		return nil
	}
	var err error
	db, err = sql.Open("sqlite3", *dbpath)
	if err != nil {
		return err
	}
	_, err = db.Exec(`create table if not exists data (ts timestamp, data blob)`)
	return err
}

func main() {
	flag.Parse()

	ctx := context.Background()

	if err := initDB(); err != nil {
		log.Fatalf("Error initializating database: %v", err)
	}

	mcli := client.New(&client.Options{
		// Define the processing of the error handler.
		ErrorHandler: func(err error) {
			log.Fatalf("Error handling MQTT: %v", err)
		},
	})

	// Connect to the MQTT Server.
	err := mcli.Connect(&client.ConnectOptions{
		CleanSession: true,
		Network:      "tcp",
		Address:      "eve:1883",
		ClientID:     []byte("tesladb"),
	})
	if err != nil {
		log.Fatalf("Error connecting to MQTT: %v", err)
	}

	delay, err := update(ctx, mcli)
	if err != nil {
		log.Fatalf("Error fetching tesla data on first run: %v", err)
	}
	for {
		if delay < time.Minute {
			log.Fatalf("Unexpectedly short delay: %v", delay)
		}
		log.Printf("Sleeping for %v", delay)
		time.Sleep(delay)
		delay, err = update(ctx, mcli)
		if err != nil {
			log.Printf("Error fetching tesla data: %v", err)
		}
	}
}
