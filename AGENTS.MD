# AGENTS.md

## Agenti Autonomi (Autopilot)

- **Autista IA Invisibile:** Il sistema Autopilot crea un solo agente autonomo: un ped (pedestrian) invisibile che entra come conducente nel veicolo personale del giocatore. Questo agente è responsabile di guidare automaticamente il veicolo.
- **Veicolo:** L’agente è sempre associato al veicolo personale del giocatore (quello su cui viene attivato l’autopilota), e utilizza le funzioni native di FiveM per controllarne il comportamento (accelerazione, sterzo, cambio di corsia, ecc.).

## Comportamenti

- **Guida al giocatore:** Quando attivato, l’agente guida il veicolo fino alla posizione corrente del giocatore.  
- **Follow automatico:** Una volta vicino al giocatore, il veicolo segue automaticamente il giocatore lungo la strada, mantenendo distanza e velocità appropriate.  
- **Parcheggio/Arresto:** Alla disattivazione l’agente ferma il veicolo e viene eliminato.

## Creazione degli Agenti

- **File e funzione di spawn:** L’agente viene creato lato client in *client.lua* nella funzione di spawn (`CreatePedInsideVehicle` o simile).  
- **Visibilità:** Il ped viene reso invisibile (`SetEntityVisible(ped, false)`).  
- **Posizione iniziale:** Inserito direttamente nel posto di guida del veicolo.

## API ed Eventi

- **Native FiveM/GTA:** Uso di `TaskVehicleDriveToCoord`, `TaskVehicleFollow`, `SetVehicleEngineOn`, `GetEntityCoords`.  
- **Eventi client-side:** Gestiti con `RegisterCommand` e `RegisterKeyMapping` per input (es. F6, comandi /autopilot).  
- **Server-side:** Comunicazione minima, solo per registrare e resettare il veicolo personale.

## Attivazione (Input)

- **Tasto F6:** Attiva o disattiva l’autopilota.  
- **Comandi aggiuntivi:** `/autopilot`, `/autopilot_stop`, `/autopilot_clear`.  
- **Condizioni:** Richiede un veicolo personale registrato.

## Distruzione e Reset

- **Rimozione:** Allo stop, l’agente viene eliminato (`DeleteEntity`).  
- **Reset del veicolo:** Rimane fermo, con parametri riportati a default.  
- **Persistenza:** L’agente non persiste oltre la sessione, viene sempre ricreato alla nuova attivazione.
